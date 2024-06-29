use starknet::{ContractAddress, ClassHash};

#[derive(Drop, Serde, starknet::Store)]
pub struct Market {
    name: ByteArray,
    market_id: u256,
    description: ByteArray,
    outcomes: (Outcome, Outcome),
    category: felt252,
    image: ByteArray,
    is_settled: bool,
    is_active: bool,
    deadline: u256,
    bet_token: ContractAddress,
    winning_outcome: Option<Outcome>,
    money_in_pool: u256,
}

#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Eq, Hash)]
pub struct Outcome {
    name: felt252,
    // currentOdds: u256,
    bought_shares: u256,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct user_position {
    amount: u256,
    has_claimed: bool,
}

#[starknet::interface]
pub trait IMarketFactory<TContractState> {
    fn create_market(
        ref self: TContractState,
        name: ByteArray,
        description: ByteArray,
        outcomes: (felt252, felt252),
        bet_token: ContractAddress,
        category: felt252,
        image: ByteArray,
        deadline: u256,
    );

    fn get_market_count(self: @TContractState) -> u256;

    fn buy_shares(ref self: TContractState, market_id: u256, token_to_mint: u8, amount: u256) -> bool;

    fn settle_market(ref self: TContractState, market_id: u256, winning_outcome: u8);

    fn toggle_market_status(ref self: TContractState, market_id: u256);

    fn claim_winnings(ref self: TContractState, market_id: u256, receiver: ContractAddress);

    fn get_market(self: @TContractState, market_id: u256) -> Market;

    fn get_all_markets(self: @TContractState) -> Array<Market>;

    fn get_market_by_category(self: @TContractState, category: felt252) -> Array<Market>;

    fn get_user_markets(self: @TContractState, user: ContractAddress) -> Array<Market>;

    fn check_for_approval(self: @TContractState, token: ContractAddress, amount: u256) -> bool;

    fn get_owner(self: @TContractState) -> ContractAddress;

    fn get_treasury_wallet(self: @TContractState) -> ContractAddress;

    fn set_treasury_wallet(ref self: TContractState, wallet: ContractAddress);

    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);

    fn get_outcome_and_bet(
        self: @TContractState, user: ContractAddress, market_id: u256
    ) -> (Outcome, user_position);

    fn get_user_total_claimable(self: @TContractState, user: ContractAddress) -> u256;

    fn has_user_placed_bet(self: @TContractState, user: ContractAddress, market_id: u256) -> bool;

    fn settle_crypto_market(ref self: TContractState, conditions: u8, amount: u256);
}

pub trait IMarketFactoryImpl<TContractState> {
    fn is_market_resolved(self: @TContractState, market_id: u256) -> bool;

    fn calc_probabilty(self: @TContractState, market_id: u256, outcome: Outcome) -> u256;
}

#[starknet::contract]
pub mod MarketFactory {
    use raize_contracts::MarketFactory::IMarketFactoryImpl;
    use openzeppelin::token::erc20::interface::IERC20DispatcherTrait;
    use core::box::BoxTrait;
    use core::option::OptionTrait;
    use core::array::ArrayTrait;
    use super::{Market, Outcome, user_position};
    use starknet::{ContractAddress, ClassHash, get_caller_address, get_contract_address};
    use core::num::traits::zero::Zero;
    use openzeppelin::token::erc20::interface::IERC20Dispatcher;
    use starknet::SyscallResultTrait;

    const one: u256 = 1_000_000_000_000_000_000;
    const MAX_ITERATIONS: u16 = 25;
    const PLATFORM_FEE: u256 = 2;
    #[storage]
    struct Storage {
        user_bet: LegacyMap::<(ContractAddress, u256), Outcome>,
        // markets: Array<Market>
        markets: LegacyMap::<u256, Market>,
        idx: u256,
        user_portfolio: LegacyMap::<
            (ContractAddress, Outcome), user_position
        >, // read outcome with market id and user name, then read portfolio using contract address and outcome.
        owner: ContractAddress,
        treasury_wallet: ContractAddress,
        admins: Array<ContractAddress>,
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MarketCreated: MarketCreated,
        ShareBought: ShareBought,
        MarketSettled: MarketSettled,
        MarketToggled: MarketToggled,
        WinningsClaimed: WinningsClaimed,
        Upgraded: Upgraded,
    }
    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct Upgraded {
        pub class_hash: ClassHash
    }
    #[derive(Drop, starknet::Event)]
    struct MarketCreated {
        market: Market
    }
    #[derive(Drop, starknet::Event)]
    struct ShareBought {
        user: ContractAddress,
        market: Market,
        outcome: Outcome,
        amount: u256
    }
    #[derive(Drop, starknet::Event)]
    struct MarketSettled {
        market: Market
    }
    #[derive(Drop, starknet::Event)]
    struct MarketToggled {
        market: Market
    }
    #[derive(Drop, starknet::Event)]
    struct WinningsClaimed {
        user: ContractAddress,
        market: Market,
        outcome: Outcome,
        amount: u256
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
    }


    fn create_share_tokens(names: (felt252, felt252)) -> (Outcome, Outcome) {
        let (name1, name2) = names;
        let mut token1 = Outcome { name: name1, bought_shares: 0 };
        let mut token2 = Outcome { name: name2, bought_shares: 0 };

        let tokens = (token1, token2);

        return tokens;
    }

    #[abi(embed_v0)]
    impl MarketFactory of super::IMarketFactory<ContractState> {
        fn create_market(
            ref self: ContractState,
            name: ByteArray,
            description: ByteArray,
            outcomes: (felt252, felt252),
            bet_token: ContractAddress,
            category: felt252,
            image: ByteArray,
            deadline: u256,
        ) {
            // the entire money stays in the contract, treasury keeps count of how much the platform is making as revenue, the rest amount in the market 
            assert(get_caller_address() == self.owner.read(), 'Only owner can create.');
            let outcomes = create_share_tokens(outcomes);
            let market = Market {
                name,
                description,
                outcomes,
                is_settled: false,
                is_active: true,
                winning_outcome: Option::None,
                bet_token: bet_token,
                money_in_pool: 0,
                category,
                image,
                deadline,
                market_id: self.idx.read() + 1,
            };
            self.idx.write(self.idx.read() + 1); // 0 -> 1
            self.markets.write(self.idx.read(), market); // write market to storage
            let current_market = self.markets.read(self.idx.read());
            self.emit(MarketCreated { market: current_market });
        }
        fn get_market(self: @ContractState, market_id: u256) -> Market {
            return self.markets.read(market_id);
        }

        fn get_market_count(self: @ContractState) -> u256 {
            return self.idx.read();
        }

        fn toggle_market_status(ref self: ContractState, market_id: u256) {
            let mut market = self.markets.read(market_id);
            market.is_active = !market.is_active;
            self.markets.write(market_id, market);
            let current_market = self.markets.read(market_id);
            self.emit(MarketToggled { market: current_market });
        }

        fn has_user_placed_bet(self: @ContractState, user: ContractAddress, market_id: u256) -> bool {
            let outcome = self.user_bet.read((user, market_id));
            return !outcome.bought_shares.is_zero();
        }

        fn check_for_approval(self: @ContractState, token: ContractAddress, amount: u256) -> bool {
            let dispatcher = IERC20Dispatcher { contract_address: token };
            let approval = dispatcher.allowance(get_caller_address(), get_contract_address());
            return approval >= amount;
        }

        fn get_user_markets(self: @ContractState, user: ContractAddress) -> Array<Market> {
            let mut markets: Array<Market> = ArrayTrait::new();
            let mut outcomes: Array<Outcome> = ArrayTrait::new();
            let mut bets: Array<user_position> = ArrayTrait::new();
            let mut i: u256 = 1;
            loop {
                if i > self.idx.read() {
                    break;
                }
                let market = self.markets.read(i);
                let (outcome1, outcome2) = market.outcomes;
                let user_outcome = self.user_bet.read((user, i));
                if user_outcome == outcome1 || user_outcome == outcome2 {
                    markets.append(market);
                    outcomes.append(user_outcome);
                    bets.append(self.user_portfolio.read((user, user_outcome)));
                }
                i += 1;
            };
            markets
        }

        fn settle_crypto_market(ref self: TContractState, conditions: u8, amount: u256) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can settle markets.');
        }

        fn get_outcome_and_bet(
            self: @ContractState, user: ContractAddress, market_id: u256
        ) -> (Outcome, user_position) {
            let outcome = self.user_bet.read((user, market_id));
            let bet = self.user_portfolio.read((user, outcome));
            return (outcome, bet);
        }

        fn get_user_total_claimable(self: @ContractState, user: ContractAddress) -> u256 {
            let mut total: u256 = 0;
            let mut i: u256 = 1;
            loop {
                if i > self.idx.read() {
                    break;
                }
                let market = self.markets.read(i);
                let user_outcome = self.user_bet.read((user, i));
                if market.is_settled == false {
                    i += 1;
                    continue;
                }
                if user_outcome == market.winning_outcome.unwrap() {
                    let user_position = self.user_portfolio.read((user, user_outcome));
                    if user_position.has_claimed == false {
                        total += user_position.amount
                            * market.money_in_pool
                            / user_outcome.bought_shares;
                    }
                }
                i += 1;
            };
            total
        }

        // creates a position in a market for a user
        fn buy_shares(
            ref self: ContractState, market_id: u256, token_to_mint: u8, amount: u256
        ) -> bool {
            let market = self.markets.read(market_id);
            assert(market.is_active == true, 'Market is not active.');
            let token = self.user_bet.read((get_caller_address(), market_id));
            let (outcome1, outcome2) = market.outcomes;
            assert(token.bought_shares.is_zero(), 'User already has shares');
            let dispatcher = IERC20Dispatcher { contract_address: market.bet_token };
            if token_to_mint == 0 {
                let mut outcome = outcome1;
                let txn: bool = dispatcher
                    .transfer_from(get_caller_address(), get_contract_address(), amount);
                dispatcher.transfer(self.treasury_wallet.read(), amount * PLATFORM_FEE / 100);
                outcome.bought_shares = outcome.bought_shares
                    + (amount - amount * PLATFORM_FEE / 100);
                let market_clone = self.markets.read(market_id);
                let money_in_pool = market_clone.money_in_pool + amount - amount * PLATFORM_FEE / 100;
                let new_market = Market {
                    outcomes: (outcome, outcome2), money_in_pool: money_in_pool, ..market_clone
                };
                self.markets.write(market_id, new_market);
                self.user_bet.write((get_caller_address(), market_id), outcome);
                self
                    .user_portfolio
                    .write(
                        (get_caller_address(), outcome),
                        user_position { amount: amount, has_claimed: false }
                    );
                let updated_market = self.markets.read(market_id);
                self
                    .emit(
                        ShareBought {
                            user: get_caller_address(),
                            market: updated_market,
                            outcome: outcome,
                            amount: amount
                        }
                    );
                txn
            } else {
                let mut outcome = outcome2;
                let txn: bool = dispatcher
                    .transfer_from(get_caller_address(), get_contract_address(), amount);
                dispatcher.transfer(self.treasury_wallet.read(), amount * PLATFORM_FEE / 100);
                outcome.bought_shares = outcome.bought_shares
                    + (amount - amount * PLATFORM_FEE / 100);
                let market_clone = self.markets.read(market_id);
                let money_in_pool = market_clone.money_in_pool + amount - amount * PLATFORM_FEE / 100;
                let marketNew = Market {
                    outcomes: (outcome1, outcome), money_in_pool: money_in_pool, ..market_clone
                };
                self.markets.write(market_id, marketNew);
                self.user_bet.write((get_caller_address(), market_id), outcome);
                self
                    .user_portfolio
                    .write(
                        (get_caller_address(), outcome),
                        user_position { amount: amount, has_claimed: false }
                    );
                let updated_market = self.markets.read(market_id);
                self
                    .emit(
                        ShareBought {
                            user: get_caller_address(),
                            market: updated_market,
                            outcome: outcome,
                            amount: amount
                        }
                    );
                txn
            }
        }

        fn get_treasury_wallet(self: @ContractState) -> ContractAddress {
            assert(get_caller_address() == self.owner.read(), 'Only owner can read.');
            return self.treasury_wallet.read();
        }

        fn claim_winnings(ref self: ContractState, market_id: u256, receiver: ContractAddress) {
            assert(market_id <= self.idx.read(), 'Market does not exist');
            let market = self.markets.read(market_id);
            assert(market.is_settled == true, 'Market not settled');
            let user_outcome: Outcome = self.user_bet.read((receiver, market_id));
            let user_position: user_position = self.user_portfolio.read((receiver, user_outcome));
            assert(user_position.has_claimed == false, 'User has claimed winnings.');
            let mut winnings = 0;
            let winning_outcome = market.winning_outcome.unwrap();
            assert(user_outcome == winning_outcome, 'User did not win!');
            winnings = user_position.amount * market.money_in_pool / user_outcome.bought_shares;
            let dispatcher = IERC20Dispatcher { contract_address: market.bet_token };
            dispatcher.transfer(receiver, winnings);
            self
                .user_portfolio
                .write(
                    (receiver, user_outcome),
                    user_position { amount: user_position.amount, has_claimed: true }
                );
            self
                .emit(
                    WinningsClaimed {
                        user: receiver, market: market, outcome: user_outcome, amount: winnings
                    }
                );
        }

        fn settreasury_wallet(ref self: ContractState, wallet: ContractAddress) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can set.');
            self.treasury_wallet.write(wallet);
        }

        fn settle_market(ref self: ContractState, market_id: u256, winning_outcome: u8) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can settle markets.');
            let mut market = self.markets.read(market_id);
            market.is_settled = true;
            market.is_active = false;
            let (outcome1, outcome2) = market.outcomes;
            if winning_outcome == 0 {
                market.winning_outcome = Option::Some(outcome1);
            } else {
                market.winning_outcome = Option::Some(outcome2);
            }
            self.markets.write(market_id, market);
            let current_market = self.markets.read(market_id);
            self.emit(MarketSettled { market: current_market });
        }

        fn get_all_markets(self: @ContractState) -> Array<Market> {
            let mut markets: Array<Market> = ArrayTrait::new();
            let mut i: u256 = 1;
            loop {
                if i > self.idx.read() {
                    break;
                }
                if self.markets.read(i).is_active == true {
                    markets.append(self.markets.read(i));
                }
                i += 1;
            };
            markets
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            return self.owner.read();
        }

        fn get_market_by_category(self: @ContractState, category: felt252) -> Array<Market> {
            let mut markets: Array<Market> = ArrayTrait::new();
            let mut i: u256 = 0;
            loop {
                if i == self.idx.read() {
                    break;
                }
                let market = self.markets.read(i);
                if market.category == category {
                    markets.append(market);
                }
                i += 1;
            };
            markets
        }

        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can upgrade.');
            starknet::syscalls::replace_class_syscall(new_class_hash).unwrap_syscall();
            self.emit(Upgraded { class_hash: new_class_hash });
        }
    }


    impl MarketFactoryImpl of super::IMarketFactoryImpl<ContractState> {
        fn is_market_resolved(self: @ContractState, market_id: u256) -> bool {
            let market = self.markets.read(market_id);
            return market.is_settled;
        }

        fn calc_probabilty(self: @ContractState, market_id: u256, outcome: Outcome) -> u256 {
            let market = self.markets.read(market_id);
            let (outcome1, outcome2) = market.outcomes;
            let total_shares = outcome1.bought_shares + outcome2.bought_shares;
            let outcome_shares = outcome.bought_shares;
            return outcome_shares / total_shares;
        }
    }
}
