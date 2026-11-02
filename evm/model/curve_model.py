#!/usr/bin/env python3
"""Stealth reference model (the curve lives in a Uniswap v4 or PancakeSwap Infinity CL pool; the fee is taken in the quote
currency).

An independent re-implementation of the protocol maths, written from the design rather than from the Solidity, using
exact rational arithmetic (fractions.Fraction, no rounding) wherever the contracts round.

A Stealth pool holds two locked positions: the curve [graduation price, launch price] and the tail
[min price, graduation price]. Inside a position the pool is a constant-product market with x*y = L^2 in sqrt-price
terms, so the exact result of any swap from a given pool state follows from L and the sqrt prices alone. The pool's
LP fee is 0; the hook takes the fee on the quote leg: a buyer pays gross = net / (1 - f) for the quote the pool needs,
a seller gets (1 - f) of the quote the pool pays out. "ETH" below means the quote currency in raw units (the native
coin or any ERC-20). The contracts (and the real pool manager) must never beat the exact result, and may only lose dust
to rounding.

Foundry calls it through ffi. Every command prints ABI-encoded uint256 words as a 0x-prefixed hex string. Sqrt prices
are Uniswap sqrtPriceX96 integers.

  vreserves <target>                      -> virtualEth, virtualToken   (integer mirror of CurveMath)
  sqrtp <ethReserve> <tokenReserve>       -> sqrtPriceX96                (integer mirror of CurveMath)
  split <fee> <ratePips> <launchType> <tierPips>
                                          -> platform, marketing, coin (integer mirror of StealthFeeVault.credit)
  coinexact <gross> <tierPips>            -> floor(70% of the tier on the trade), from the design: the coin's part
  sniper <tierPips> <elapsed>             -> the rate at that many whole seconds after launch (mirror of StealthHook)
  team <accrued> <bps0> <bps1> ...        -> each wallet's lifetime earnings (mirror of StealthFeeVault._earned)
  grad <sqrtGrad> <sqrtStart> <Lcurve>    -> floor(exact ETH the curve holds at the graduation price),
                                             floor(exact tokens the curve holds at the launch price)
  buycost <S> <Sg> <Ss> <St> <Lc> <Lt> <feePips> <tokensOut>
                                          -> ceil(exact ETH, fee included, to buy tokensOut from price S)
  sellvalue <S> <Sg> <Ss> <St> <Lc> <Lt> <feePips> <tokensIn>
                                          -> floor(exact ETH out for selling tokensIn at price S), ok
     (S = current price, Sg = graduation, Ss = launch, St = tail bottom; ok = 0 if the sell would pass the launch
      price, which the hook refuses)
"""
import sys
from fractions import Fraction
from math import isqrt, floor, ceil

BPS = 10_000
PIPS = 1_000_000
TOTAL = 1_000_000_000 * 10**18
CURVE = 800_000_000 * 10**18
POOL = 200_000_000 * 10**18
COIN_TAX_BPS = 7_000      # 70% of the coin's tier for the coin, the rest of what the trade paid for the platform
SNIPER_START = 900_000    # 90%
SNIPER_WINDOW = 15        # seconds
CREATOR, TEAM, MARKETING, HOLDERS, BUYBACK, POT = 0, 1, 2, 3, 4, 5
Q96 = 2**96


def enc(*vals):
    for v in vals:
        if v < 0 or v >= 2**256:
            raise ValueError(f"out of uint256 range: {v}")
    return "0x" + "".join(format(v, "064x") for v in vals)


# ---------------------------------------------------------------------------
# Integer mirrors (must match the contracts to the wei)
# ---------------------------------------------------------------------------

def vreserves(target):
    virtual_eth = POOL * target // (CURVE - POOL)
    virtual_token = CURVE + POOL * (virtual_eth + target) // target
    return virtual_eth, virtual_token


def sqrtp(quote_reserve, token_reserve):
    # Mirrors CurveMath.sqrtPriceX96, including its second form for ratios of 2^64 and more.
    if token_reserve < (quote_reserve << 64):
        return isqrt((token_reserve << 192) // quote_reserve)
    return isqrt((token_reserve << 128) // quote_reserve) << 32


def split(fee, rate, launch_type, tier):
    """StealthFeeVault.credit: the coin's part, 70% of its tier on the trade, is fee * (tier * 70%) / rate; the platform
    gets the rest. Marketing takes all of the coin's part on the Marketing type and none of it on any other. Returns
    (platform, marketing, coin), where coin is what stays with the coin."""
    coin = fee * (tier * COIN_TAX_BPS // BPS) // rate
    marketing = coin if launch_type == MARKETING else 0
    return fee - coin, marketing, coin - marketing


def coin_exact(gross, tier):
    """The design: the coin gets 70% of its tier on the trade's gross quote leg, whatever the rate."""
    return gross * (tier * COIN_TAX_BPS // BPS) // PIPS


def sniper(tier, elapsed):
    """Meteora's linear scheduler on Solana: 90% at launch, one equal step down per second, the tier from second 15."""
    if elapsed >= SNIPER_WINDOW:
        return tier
    return SNIPER_START - (SNIPER_START - tier) * elapsed // SNIPER_WINDOW


def team_earned(accrued, bps):
    """Wallets 1.. earn floor(accrued * bps / 10000) for life; wallet 0 takes the remainder."""
    shares = [accrued * b // BPS for b in bps[1:]]
    return [accrued - sum(shares)] + shares


# ---------------------------------------------------------------------------
# Exact pool maths
# ---------------------------------------------------------------------------

def eth_between(L, s_lo, s_hi):
    """Token0 (ETH) a position of liquidity L holds between two sqrt prices: L * Q96 * (1/s_lo - 1/s_hi)."""
    return Fraction(L * Q96) * (Fraction(1, s_lo) - Fraction(1, s_hi))


def tokens_between(L, s_lo, s_hi):
    """Token1 a position of liquidity L holds between two sqrt prices: L * (s_hi - s_lo) / Q96."""
    return Fraction(L) * (Fraction(s_hi) - Fraction(s_lo)) / Q96


def grad(sg, ss, lc):
    return floor(eth_between(lc, sg, ss)), floor(tokens_between(lc, sg, ss))


def buy_cost(s, sg, ss, st, lc, lt, fee, tokens_out):
    """Exact ETH (fee included) a buyer must pay to receive tokens_out, starting at sqrt price s. Price falls."""
    s = Fraction(s)
    remaining = Fraction(tokens_out)
    net = Fraction(0)
    while remaining > 0:
        # Moving down, the curve is active strictly above the graduation price, the tail at or below it.
        liquidity, bound = (lc, Fraction(sg)) if s > sg else (lt, Fraction(st))
        room = tokens_between(liquidity, bound, s)
        if remaining >= room:
            if bound == st:
                raise ValueError("buy runs past the bottom of the tail")
            net += eth_between(liquidity, bound, s)
            remaining -= room
            s = bound
        else:
            s_new = s - remaining * Q96 / liquidity
            net += eth_between(liquidity, s_new, s)
            remaining = 0
    return net * PIPS / (PIPS - fee)


def sell_value(s, sg, ss, st, lc, lt, fee, tokens_in):
    """Exact ETH the seller receives for tokens_in at sqrt price s: every token is swapped, then the fee comes out
    of the ETH. Price rises. None if it would pass ss."""
    s = Fraction(s)
    net = Fraction(tokens_in)
    out = Fraction(0)
    while net > 0:
        # Moving up, the tail is active strictly below the graduation price, the curve at or above it.
        if s < sg:
            liquidity, bound = lt, Fraction(sg)
        elif s < ss:
            liquidity, bound = lc, Fraction(ss)
        else:
            return None
        room = tokens_between(liquidity, s, bound)
        if net >= room:
            out += eth_between(liquidity, s, bound)
            net -= room
            s = bound
        else:
            s_new = s + net * Q96 / liquidity
            out += eth_between(liquidity, s, s_new)
            net = 0
    return out * (PIPS - fee) / PIPS


def main(argv):
    cmd, args = argv[1], [int(a) for a in argv[2:]]
    if cmd == "vreserves":
        out = vreserves(args[0])
    elif cmd == "sqrtp":
        out = (sqrtp(args[0], args[1]),)
    elif cmd == "split":
        out = split(*args)
    elif cmd == "coinexact":
        out = (coin_exact(args[0], args[1]),)
    elif cmd == "sniper":
        out = (sniper(args[0], args[1]),)
    elif cmd == "team":
        out = tuple(team_earned(args[0], args[1:]))
    elif cmd == "grad":
        out = grad(*args)
    elif cmd == "buycost":
        out = (ceil(buy_cost(*args)),)
    elif cmd == "sellvalue":
        v = sell_value(*args)
        out = (0, 0) if v is None else (floor(v), 1)
    else:
        raise SystemExit(f"unknown command {cmd}")
    sys.stdout.write(enc(*out))


if __name__ == "__main__":
    main(sys.argv)
