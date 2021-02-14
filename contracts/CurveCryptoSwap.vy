# @version 0.2.8
# (c) Curve.Fi, 2020
# Pool for 3Crv(USD)/BTC/ETH or similar
from vyper.interfaces import ERC20

interface CurveToken:
    def totalSupply() -> uint256: view
    def mint(_to: address, _value: uint256) -> bool: nonpayable
    def mint_relative(_to: address, frac: uint256) -> bool: nonpayable
    def burnFrom(_to: address, _value: uint256) -> bool: nonpayable


interface Math:
    def geometric_mean(unsorted_x: uint256[N_COINS]) -> uint256: view
    def reduction_coefficient(x: uint256[N_COINS], gamma: uint256) -> uint256: view
    def newton_D(ANN: uint256, gamma: uint256, x_unsorted: uint256[N_COINS]) -> uint256: view
    def newton_y(ANN: uint256, gamma: uint256, x: uint256[N_COINS], D: uint256, i: uint256) -> uint256: view
    def halfpow(power: uint256, precision: uint256) -> uint256: view
    def sqrt_int(x: uint256) -> uint256: view


# Events
event TokenExchange:
    buyer: indexed(address)
    sold_id: uint256
    tokens_sold: uint256
    bought_id: uint256
    tokens_bought: uint256

event AddLiquidity:
    provider: indexed(address)
    token_amounts: uint256[N_COINS]
    fee: uint256
    token_supply: uint256

event RemoveLiquidity:
    provider: indexed(address)
    token_amounts: uint256[N_COINS]
    token_supply: uint256

event RemoveLiquidityOne:
    provider: indexed(address)
    token_amount: uint256
    coin_amount: uint256


N_COINS: constant(int128) = 3  # <- change
PRECISION_MUL: constant(uint256[N_COINS]) = [1, 1, 1]  # 3usd, renpool, eth
FEE_DENOMINATOR: constant(uint256) = 10 ** 10
PRECISION: constant(uint256) = 10 ** 18  # The precision to convert to
A_MULTIPLIER: constant(uint256) = 100

math: constant(address) = 0x0000000000000000000000000000000000000000

price_scale: public(uint256[N_COINS-1])   # Internal price scale
price_oracle: public(uint256[N_COINS-1])  # Price target given by MA

last_prices: public(uint256[N_COINS-1])
last_prices_timestamp: public(uint256)

initial_A: public(uint256)
future_A: public(uint256)
initial_A_time: public(uint256)
future_A_time: public(uint256)

gamma: public(uint256)
mid_fee: public(uint256)
out_fee: public(uint256)
price_threshold: public(uint256)
fee_gamma: public(uint256)
adjustment_step: public(uint256)
ma_half_time: public(uint256)

balances: public(uint256[N_COINS])
coins: public(address[N_COINS])
D: public(uint256)

token: public(address)
owner: public(address)

admin_fee: public(uint256)

xcp_profit_real: public(uint256)  # xcp_profit_real in simulation
xcp_profit: uint256
xcp: uint256

is_killed: public(bool)
kill_deadline: uint256
KILL_DEADLINE_DT: constant(uint256) = 2 * 30 * 86400


@external
def __init__(
    owner: address,
    coins: address[N_COINS],
    pool_token: address,
    A: uint256,
    gamma: uint256,
    mid_fee: uint256,
    out_fee: uint256,
    price_threshold: uint256,
    fee_gamma: uint256,
    adjustment_step: uint256,
    admin_fee: uint256,
    ma_half_time: uint256,
    initial_prices: uint256[N_COINS-1]
):
    self.owner = owner
    self.coins = coins
    self.token = pool_token
    self.initial_A = A * A_MULTIPLIER
    self.future_A = A * A_MULTIPLIER
    self.gamma = gamma
    self.mid_fee = mid_fee
    self.out_fee = out_fee
    self.price_threshold = price_threshold
    self.fee_gamma = fee_gamma
    self.adjustment_step = adjustment_step
    self.admin_fee = admin_fee
    new_initial_prices: uint256[N_COINS-1] = initial_prices
    precisions: uint256[N_COINS] = PRECISION_MUL
    new_initial_prices[0] = precisions[0] * PRECISION  # First price is always 1e18
    self.price_scale = new_initial_prices
    self.price_oracle = new_initial_prices
    self.last_prices = new_initial_prices
    self.last_prices_timestamp = block.timestamp
    self.ma_half_time = ma_half_time

    self.kill_deadline = block.timestamp + KILL_DEADLINE_DT


@internal
@view
def xp() -> uint256[N_COINS]:
    result: uint256[N_COINS] = self.balances
    # PRECISION_MUL is already contained in self.price_scale
    for i in range(N_COINS-1):
        result[i+1] = result[i+1] * self.price_scale[i] / PRECISION
    return result


@view
@internal
def _A() -> uint256:
    t1: uint256 = self.future_A_time
    A1: uint256 = self.future_A

    if block.timestamp < t1:
        # handle ramping up and down of A
        A0: uint256 = self.initial_A
        t0: uint256 = self.initial_A_time
        # Expressions in uint256 cannot have negative numbers, thus "if"
        if A1 > A0:
            return A0 + (A1 - A0) * (block.timestamp - t0) / (t1 - t0)
        else:
            return A0 - (A0 - A1) * (block.timestamp - t0) / (t1 - t0)

    else:  # when t1 == 0 or block.timestamp >= t1
        return A1


@view
@external
def A() -> uint256:
    return self._A() / A_MULTIPLIER


@view
@external
def A_precise() -> uint256:
    return self._A()


###################################
#           Actual logic          #
###################################
@internal
@view
def _fee(xp: uint256[N_COINS]) -> uint256:
    f: uint256 = Math(math).reduction_coefficient(xp, self.fee_gamma)
    return (self.mid_fee * f + self.out_fee * (10**18 - f)) / 10**18


@external
@view
def fee() -> uint256:
    return self._fee(self.xp())


@internal
@view
def get_xcp(_D: uint256 = 0) -> uint256:
    D: uint256 = _D
    if D == 0:
        D = self.D
    x: uint256[N_COINS] = empty(uint256[N_COINS])
    x[0] = D / N_COINS
    for i in range(N_COINS-1):
        x[i+1] = D * 10**18 / (N_COINS * self.price_oracle[i])
    return Math(math).geometric_mean(x)


@external
@view
def get_virtual_price() -> uint256:
    # XXX save virtual price at the very first liquidity deposit
    # and divide by it here to have virtual_price starting from 1.0
    return self.get_xcp() * 10**18 / CurveToken(self.token).totalSupply()


@internal
def update_xcp(only_real: bool = False):
    xcp: uint256 = self.get_xcp()
    old_xcp: uint256 = self.xcp
    self.xcp_profit_real = self.xcp_profit_real * xcp / old_xcp
    if not only_real:
        self.xcp_profit = self.xcp_profit * xcp / old_xcp
    self.xcp = xcp


@internal
def tweak_price(A: uint256, gamma: uint256, _xp: uint256[N_COINS], i: uint256, dx: uint256, j: uint256, dy: uint256):
    """
    dx of coin i -> dy of coin j

    TODO: this can be compressed by having each number being 128 bits
    """
    # Update MA if needed
    price_oracle: uint256[N_COINS-1] = self.price_oracle
    last_prices_timestamp: uint256 = self.last_prices_timestamp
    last_prices: uint256[N_COINS-1] = self.last_prices
    if last_prices_timestamp < block.timestamp:
        # MA update required
        ma_half_time: uint256 = self.ma_half_time
        alpha: uint256 = Math(math).halfpow((block.timestamp - last_prices_timestamp) * 10**18 / ma_half_time, 10**10)
        for k in range(N_COINS-1):
            price_oracle[k] = (last_prices[k] * (10**18 - alpha) + price_oracle[k] * alpha) / 10**18
        self.price_oracle = price_oracle
        self.last_prices_timestamp = block.timestamp

    # We will need this a few times (35k gas)
    D_unadjusted: uint256 = Math(math).newton_D(A, gamma, _xp)
    price_scale: uint256[N_COINS-1] = self.price_scale

    if i > 0 or j > 0:
        # Save the last price
        p: uint256 = 0
        ix: uint256 = j
        if i != 0 and j != 0:
            p = last_prices[i-1] * dx / dy
        elif i == 0:
            p = dx * 10**18 / dy
        else:  # j == 0
            p = dy * 10**18 / dx
            ix = i
        self.last_prices[ix-1] = p
    else:
        # calculate real prices
        # it would cost 70k gas for a 3-token pool. Sad. How do we do better?
        __xp: uint256[N_COINS] = _xp
        __xp[0] += 10**18
        for k in range(N_COINS-1):
            self.last_prices[k] = price_scale[k] * 10**18 / (_xp[k+1] - Math(math).newton_y(A, gamma, __xp, D_unadjusted, k+1))

    norm: uint256 = 0
    old_xcp_profit: uint256 = self.xcp_profit
    old_xcp_profit_real: uint256 = self.xcp_profit_real
    for k in range(N_COINS-1):
        ratio: uint256 = price_oracle[k] * 10**18 / price_scale[k]
        if ratio > 10**18:
            ratio -= 10**18
        else:
            ratio = 10**18 - ratio
        norm += ratio**2


    # Update profit numbers without price adjustment first
    # XXX should we leave it like this or call get_xcp?
    xp: uint256[N_COINS] = empty(uint256[N_COINS])
    xp[0] = D_unadjusted / N_COINS
    for k in range(N_COINS-1):
        xp[k+1] = D_unadjusted * 10**18 / (N_COINS * price_scale[k])
    old_xcp: uint256 = self.xcp
    xcp: uint256 = Math(math).geometric_mean(xp)
    xcp_profit_real: uint256 = old_xcp_profit_real * xcp / old_xcp
    xcp_profit: uint256 = old_xcp_profit * xcp / old_xcp
    self.xcp_profit = xcp_profit

    # Mint admin fees
    frac: uint256 = (10**18 * xcp / old_xcp - 10**18) * self.admin_fee / (2 * 10**10)
    # /2 here is because half of the fee usually goes for retargeting the price
    if frac > 0:
        assert CurveToken(self.token).mint_relative(self.owner, frac)

    # self.price_threshold must be > self.adjustment_step
    # should we pause for a bit if profit wasn't enough to not spend this gas every time?
    if norm > self.price_threshold ** 2:
        norm = Math(math).sqrt_int(norm)
        adjustment_step: uint256 = self.adjustment_step

        p_new: uint256[N_COINS-1] = empty(uint256[N_COINS-1])
        for k in range(N_COINS-1):
            p_new[k] = (price_scale[k] * (norm - adjustment_step) + adjustment_step * price_oracle[k]) / norm

        # Calculate balances*prices
        xp = _xp
        for k in range(N_COINS-1):
            xp[k+1] = _xp[k+1] * p_new[k] / price_scale[k]

        # Calculate "extended constant product" invariant xCP
        D: uint256 = Math(math).newton_D(A, gamma, xp)
        xp[0] = D / N_COINS
        for k in range(N_COINS-1):
            xp[k+1] = D * 10**18 / (N_COINS * p_new[k])
        xcp = Math(math).geometric_mean(xp)
        old_xcp_profit_real = old_xcp_profit_real * xcp / old_xcp  # Just reusing a variable here: it's not old anymore

        # Proceed if we've got enough profit
        if 2 * (old_xcp_profit_real - 10**18) > xcp_profit - 10**18:
            self.price_scale = p_new
            self.D = D
            self.xcp_profit_real = old_xcp_profit_real
            return

        # else - make a delay?

    # If we are here, the price_scale adjustment did not happen
    # Still need to update the profit counter and D
    self.D = D_unadjusted
    self.xcp_profit_real = xcp_profit_real


@external
@nonreentrant('lock')
def exchange(i: uint256, j: uint256, dx: uint256, min_dy: uint256):
    assert not self.is_killed  # dev: the pool is killed
    assert i != j and i < N_COINS and j < N_COINS

    input_coin: address = self.coins[i]
    assert ERC20(input_coin).transferFrom(msg.sender, self, dx)

    price_scale: uint256[N_COINS-1] = self.price_scale
    xp: uint256[N_COINS] = self.balances
    y0: uint256 = xp[j]
    xp[i] += dx
    for k in range(N_COINS-1):
        xp[k+1] = xp[k+1] * price_scale[k] / PRECISION

    A: uint256 = self._A()
    gamma: uint256 = self.gamma

    y: uint256 = Math(math).newton_y(A, gamma, xp, self.D, j)
    dy: uint256 = xp[j] - y - 1
    xp[j] = y
    if j > 0:
        dy = dy * PRECISION / price_scale[j-1]
    dy -= self._fee(xp) * dy / 10**10
    assert dy >= min_dy, "Exchange resulted in fewer coins than expected"

    self.balances[j] = y0 - dy
    output_coin: address = self.coins[j]
    assert ERC20(output_coin).transfer(msg.sender, dy)

    if j == 0:
        xp[0] = y0 - dy
    else:
        xp[j] = (y0 - dy) * price_scale[j-1] / PRECISION
    self.tweak_price(A, gamma, xp, i, dx, j, dy)

    log TokenExchange(msg.sender, i, dx, j, dy)


@external
@view
def get_dy(i: uint256, j: uint256, dx: uint256) -> uint256:
    assert i != j and i < N_COINS and j < N_COINS

    price_scale: uint256[N_COINS-1] = self.price_scale
    xp: uint256[N_COINS] = self.balances
    y0: uint256 = xp[j]
    xp[i] += dx
    for k in range(N_COINS-1):
        xp[k+1] = xp[k+1] * price_scale[k] / PRECISION

    A: uint256 = self._A()
    gamma: uint256 = self.gamma

    y: uint256 = Math(math).newton_y(A, gamma, xp, self.D, j)
    dy: uint256 = xp[j] - y - 1
    xp[j] = y
    if j > 0:
        dy = dy * PRECISION / price_scale[j-1]
    dy -= self._fee(xp) * dy / 10**10

    return dy


@external
@nonreentrant('lock')
def add_liquidity(amounts: uint256[N_COINS], min_mint_amount: uint256):
    assert not self.is_killed  # dev: the pool is killed

    for i in range(N_COINS):
        assert ERC20(self.coins[i]).transferFrom(msg.sender, self, amounts[i])

    price_scale: uint256[N_COINS-1] = self.price_scale
    xp: uint256[N_COINS] = self.balances
    for i in range(N_COINS):
        self.balances[i] = xp[i] + amounts[i]
    xp[0] += amounts[0]
    for i in range(N_COINS-1):
        xp[i+1] = (xp[i+1] + amounts[i+1]) * price_scale[i] / PRECISION
    A: uint256 = self._A()
    gamma: uint256 = self.gamma
    token: address = self.token

    D: uint256 = Math(math).newton_D(A, gamma, xp)

    token_supply: uint256 = CurveToken(token).totalSupply()
    d_token: uint256 = token_supply * D / self.D
    assert d_token > 0  # dev: nothing minted
    d_token_fee: uint256 = self._fee(xp) * d_token / (2 * 10**10) + 1  # /2 because it's half a trade
    d_token -= d_token_fee
    assert d_token >= min_mint_amount, "Slippage screwed you"

    assert CurveToken(token).mint(msg.sender, d_token)

    self.tweak_price(A, gamma, xp, 0, 0, 0, 0)

    log AddLiquidity(msg.sender, amounts, d_token_fee, token_supply)

@external
@nonreentrant('lock')
def remove_liquidity(_amount: uint256, min_amounts: uint256[N_COINS]):
    token: address = self.token
    total_supply: uint256 = CurveToken(token).totalSupply()
    assert CurveToken(token).burnFrom(msg.sender, _amount)
    balances: uint256[N_COINS] = self.balances

    for i in range(N_COINS):
        d_balance: uint256 = balances[i] * _amount / total_supply
        assert d_balance >= min_amounts[i]
        self.balances[i] = balances[i] - d_balance
        balances[i] = d_balance  # now it's the amounts going out
        assert ERC20(self.coins[i]).transfer(msg.sender, d_balance)

    log RemoveLiquidity(msg.sender, balances, total_supply - _amount)


@view
@external
def calc_token_amount(amounts: uint256[N_COINS], deposit: bool) -> uint256:
    token_supply: uint256 = CurveToken(self.token).totalSupply()
    xp: uint256[N_COINS] = self.balances
    if deposit:
        for k in range(N_COINS):
            xp[k] += amounts[k]
    else:
        for k in range(N_COINS):
            xp[k] -= amounts[k]
    for k in range(N_COINS-1):
        xp[k+1] = xp[k+1] * self.price_scale[k] / PRECISION
    D: uint256 = Math(math).newton_D(self._A(), self.gamma, xp)
    fee: uint256 = self._fee(xp)
    d_token: uint256 = token_supply * D / self.D
    if deposit:
        d_token -= token_supply
    else:
        d_token = token_supply - d_token
    d_token -= fee * d_token / (2 * 10**10) + 1
    return d_token


@internal
@view
def _calc_withdraw_one_coin(A: uint256, gamma: uint256, token_amount: uint256, i: uint256) -> (uint256, uint256[N_COINS]):
    D: uint256 = self.D
    token_supply: uint256 = CurveToken(self.token).totalSupply()

    xp: uint256[N_COINS] = self.balances
    y0: uint256 = xp[i]
    price_scale: uint256[N_COINS-1] = self.price_scale
    for k in range(N_COINS-1):
        xp[k+1] = xp[k+1] * price_scale[k] / PRECISION

    D = D * (token_supply - token_amount) / token_supply
    dy: uint256 = Math(math).newton_y(A, gamma, xp, D, i)
    if i > 0:
        dy = dy * PRECISION / price_scale[i-1]
    dy = y0 - dy
    fee: uint256 = self._fee(xp) * dy / (2 * 10**10) + 1
    dy -= fee

    return dy, xp


@view
@external
def calc_withdraw_one_coin(token_amount: uint256, i: uint256) -> uint256:
    return self._calc_withdraw_one_coin(self._A(), self.gamma, token_amount, i)[0]


@external
@nonreentrant('lock')
def remove_liquidity_one_coin(token_amount: uint256, i: uint256, min_amount: uint256):
    assert not self.is_killed  # dev: the pool is killed

    token: address = self.token
    assert CurveToken(self.token).burnFrom(msg.sender, token_amount)
    A: uint256 = self._A()
    gamma: uint256 = self.gamma

    dy: uint256 = 0
    xp: uint256[N_COINS] = empty(uint256[N_COINS])
    dy, xp = self._calc_withdraw_one_coin(A, gamma, token_amount, i)
    assert dy >= min_amount, "Slippage screwed you"

    self.balances[i] -= dy
    assert ERC20(self.coins[i]).transfer(msg.sender, dy)

    self.tweak_price(A, gamma, xp, 0, 0, 0, 0)

    log RemoveLiquidityOne(msg.sender, token_amount, dy)

# XXX not sure if remove_liquidity_imbalance is used by anyone - can remove


# Admin parameters
@external
def ramp_A(_future_A: uint256, _future_time: uint256):
    pass


@external
def stop_ramp_A():
    pass


@external
def commit_new_fees(new_mid_fee: uint256, new_out_fee: uint256, new_admin_fee: uint256):
    pass


@external
def apply_new_fees():
    pass


@external
def revert_new_parameters():
    pass


@external
def commit_transfer_ownership(_owner: address):
    pass


@external
def apply_transfer_ownership():
    pass


@external
def revert_transfer_ownership():
    pass


@external
def withdraw_admin_fees():
    # Wrap as pool token and withdraw
    pass


@external
def kill_me():
    assert msg.sender == self.owner  # dev: only owner
    assert self.kill_deadline > block.timestamp  # dev: deadline has passed
    self.is_killed = True


@external
def unkill_me():
    assert msg.sender == self.owner  # dev: only owner
    self.is_killed = False
