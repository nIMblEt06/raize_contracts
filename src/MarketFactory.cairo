use starknet::{ContractAddress, ClassHash};
use pragma_lib::types::{AggregationMode, DataType, PragmaPricesResponse};

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
    winning_outcome: Option<Outcome>,
    money_in_pool: u256,
}

#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Eq, Hash)]
pub struct Outcome {
    name: felt252,
    bought_shares: u256,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct UserPosition {
    amount: u256,
    has_claimed: bool,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct UserBet {
    outcome: Outcome,
    position: UserPosition
}

#[starknet::interface]
pub trait IMarketFactory<TContractState> {
    fn create_market(
        ref self: TContractState,
        name: ByteArray,
        description: ByteArray,
        outcomes: (felt252, felt252),
        category: felt252,
        image: ByteArray,
        deadline: u256,
    );

    fn get_market_count(self: @TContractState) -> u256;

    fn buy_shares(
        ref self: TContractState, market_id: u256, token_to_mint: u8, amount: u256
    ) -> bool;

    fn settle_market(ref self: TContractState, market_id: u256, winning_outcome: u8);

    fn toggle_market_status(ref self: TContractState, market_id: u256);

    fn claim_winnings(ref self: TContractState, market_id: u256);

    fn get_market(self: @TContractState, market_id: u256) -> Market;

    fn get_all_markets(self: @TContractState) -> Array<Market>;

    fn get_market_by_category(self: @TContractState, category: felt252) -> Array<Market>;

    fn get_user_markets(self: @TContractState, user: ContractAddress) -> Array<Market>;

    fn get_owner(self: @TContractState) -> ContractAddress;

    fn get_treasury_wallet(self: @TContractState) -> ContractAddress;

    fn set_treasury_wallet(ref self: TContractState, wallet: ContractAddress);

    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);

    fn get_outcome_and_bet(
        self: @TContractState, user: ContractAddress, market_id: u256
    ) -> UserBet;

    fn get_user_total_claimable(self: @TContractState, user: ContractAddress) -> u256;

    fn has_user_placed_bet(self: @TContractState, user: ContractAddress, market_id: u256) -> bool;

    fn settle_crypto_market(
        ref self: TContractState,
        market_id: u256,
        current_timestamp: u256,
        price_key: felt252,
        conditions: u8,
        amount: u128
    );

    fn add_admin(ref self: TContractState, admin: ContractAddress);

    fn remove_all_markets(ref self: TContractState);
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
    use super::{Market, Outcome, UserPosition, UserBet};
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_contract_address, contract_address_const
    };
    use core::num::traits::zero::Zero;
    use openzeppelin::token::erc20::interface::IERC20Dispatcher;
    use starknet::SyscallResultTrait;
    use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use pragma_lib::types::{AggregationMode, DataType, PragmaPricesResponse};
    const one: u256 = 1_000_000_000_000_000_000;
    const MAX_ITERATIONS: u16 = 25;
    const PLATFORM_FEE: u256 = 2;

    #[storage]
    struct Storage {
        user_bet: LegacyMap::<(ContractAddress, u256), UserBet>,
        markets: LegacyMap::<u256, Market>,
        idx: u256,
        owner: ContractAddress,
        treasury_wallet: ContractAddress,
        admins: LegacyMap::<u128, ContractAddress>,
        num_admins: u128,
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
            category: felt252,
            image: ByteArray,
            deadline: u256,
        ) {
            let mut i = 1;
            loop {
                if i > self.num_admins.read() {
                    panic!("Only admins can create markets.");
                }
                if self.admins.read(i) == get_caller_address() {
                    break;
                }
                i += 1;
            };
            let outcomes = create_share_tokens(outcomes);
            let market = Market {
                name,
                description,
                outcomes,
                is_settled: false,
                is_active: true,
                winning_outcome: Option::None,
                money_in_pool: 0,
                category,
                image,
                deadline,
                market_id: self.idx.read() + 1,
            };
            self.idx.write(self.idx.read() + 1);
            self.markets.write(self.idx.read(), market);
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

        fn has_user_placed_bet(
            self: @ContractState, user: ContractAddress, market_id: u256
        ) -> bool {
            let user_bet = self.user_bet.read((user, market_id));
            return !user_bet.outcome.bought_shares.is_zero();
        }

        fn get_user_markets(self: @ContractState, user: ContractAddress) -> Array<Market> {
            let mut markets: Array<Market> = ArrayTrait::new();
            let mut i: u256 = 1;
            loop {
                if i > self.idx.read() {
                    break;
                }
                let user_bet = self.user_bet.read((user, i));
                if user_bet.outcome.bought_shares > 0 {
                    markets.append(self.markets.read(i));
                }
                i += 1;
            };
            markets
        }

        fn settle_crypto_market(
            ref self: ContractState,
            market_id: u256,
            current_timestamp: u256,
            price_key: felt252,
            conditions: u8,
            amount: u128
        ) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can settle markets.');
            assert(market_id <= self.idx.read(), 'Market does not exist');
            let price = get_asset_price_median(DataType::SpotEntry(price_key));
            let mut market = self.markets.read(market_id);
            assert(current_timestamp > market.deadline, 'Market has not expired.');
            market.is_settled = true;
            market.is_active = false;
            let (outcome1, outcome2) = market.outcomes;
            if conditions == 0 {
                if price > amount {
                    market.winning_outcome = Option::Some(outcome1);
                } else {
                    market.winning_outcome = Option::Some(outcome2);
                }
            } else {
                if price < amount {
                    market.winning_outcome = Option::Some(outcome1);
                } else {
                    market.winning_outcome = Option::Some(outcome2);
                }
            }
            self.markets.write(market_id, market);
            let current_market = self.markets.read(market_id);
            self.emit(MarketSettled { market: current_market });
        }

        fn get_outcome_and_bet(
            self: @ContractState, user: ContractAddress, market_id: u256
        ) -> UserBet {
            let user_bet = self.user_bet.read((user, market_id));
            return user_bet;
        }

        fn add_admin(ref self: ContractState, admin: ContractAddress) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can add admins.');
            self.num_admins.write(self.num_admins.read() + 1);
            self.admins.write(self.num_admins.read(), admin);
        }

        fn get_user_total_claimable(self: @ContractState, user: ContractAddress) -> u256 {
            let mut total: u256 = 0;
            let mut i: u256 = 1;
            loop {
                if i > self.idx.read() {
                    break;
                }
                let market = self.markets.read(i);
                let user_bet = self.user_bet.read((user, i));
                if market.is_settled == false {
                    i += 1;
                    continue;
                }
                if user_bet.outcome == market.winning_outcome.unwrap() {
                    if user_bet.position.has_claimed == false {
                        total += user_bet.position.amount
                            * market.money_in_pool
                            / user_bet.outcome.bought_shares;
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
            let user_bet = self.user_bet.read((get_caller_address(), market_id));
            let (outcome1, outcome2) = market.outcomes;
            assert(user_bet.outcome.bought_shares.is_zero(), 'User already has shares');
            let usdc_address = contract_address_const::<
                0x053b40a647cedfca6ca84f542a0fe36736031905a9639a7f19a3c1e66bfd5080
            >();
            let dispatcher = IERC20Dispatcher { contract_address: usdc_address };
            if token_to_mint == 0 {
                let mut outcome = outcome1;
                let txn: bool = dispatcher
                    .transfer_from(get_caller_address(), get_contract_address(), amount);
                dispatcher.transfer(self.treasury_wallet.read(), amount * PLATFORM_FEE / 100);
                outcome.bought_shares = outcome.bought_shares
                    + (amount - amount * PLATFORM_FEE / 100);
                let market_clone = self.markets.read(market_id);
                let money_in_pool = market_clone.money_in_pool
                    + amount
                    - amount * PLATFORM_FEE / 100;
                let new_market = Market {
                    outcomes: (outcome, outcome2), money_in_pool: money_in_pool, ..market_clone
                };
                self.markets.write(market_id, new_market);
                self
                    .user_bet
                    .write(
                        (get_caller_address(), market_id),
                        UserBet {
                            outcome: outcome,
                            position: UserPosition { amount: amount, has_claimed: false }
                        }
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
                let money_in_pool = market_clone.money_in_pool
                    + amount
                    - amount * PLATFORM_FEE / 100;
                let marketNew = Market {
                    outcomes: (outcome1, outcome), money_in_pool: money_in_pool, ..market_clone
                };
                self.markets.write(market_id, marketNew);
                self
                    .user_bet
                    .write(
                        (get_caller_address(), market_id),
                        UserBet {
                            outcome: outcome,
                            position: UserPosition { amount: amount, has_claimed: false }
                        }
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

        fn remove_all_markets(ref self: ContractState) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can remove markets.');
            self.idx.write(0);
        }

        fn get_treasury_wallet(self: @ContractState) -> ContractAddress {
            assert(get_caller_address() == self.owner.read(), 'Only owner can read.');
            return self.treasury_wallet.read();
        }

        fn claim_winnings(ref self: ContractState, market_id: u256) {
            assert(market_id <= self.idx.read(), 'Market does not exist');
            let market = self.markets.read(market_id);
            assert(market.is_settled == true, 'Market not settled');
            let user_bet: UserBet = self.user_bet.read((get_caller_address(), market_id));
            assert(user_bet.position.has_claimed == false, 'User has claimed winnings.');
            let mut winnings = 0;
            let winning_outcome = market.winning_outcome.unwrap();
            assert(user_bet.outcome == winning_outcome, 'User did not win!');
            winnings = user_bet.position.amount
                * market.money_in_pool
                / user_bet.outcome.bought_shares;
            let usdc_address = contract_address_const::<
                0x053b40a647cedfca6ca84f542a0fe36736031905a9639a7f19a3c1e66bfd5080
            >();
            let dispatcher = IERC20Dispatcher { contract_address: usdc_address };
            dispatcher.transfer(get_caller_address(), winnings);
            self
                .user_bet
                .write(
                    (get_caller_address(), market_id),
                    UserBet {
                        outcome: user_bet.outcome,
                        position: UserPosition {
                            amount: user_bet.position.amount, has_claimed: true
                        }
                    }
                );
            self
                .emit(
                    WinningsClaimed {
                        user: get_caller_address(),
                        market: market,
                        outcome: user_bet.outcome,
                        amount: winnings
                    }
                );
        }

        fn set_treasury_wallet(ref self: ContractState, wallet: ContractAddress) {
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

    fn get_asset_price_median(asset: DataType) -> u128 {
        let oracle_address: ContractAddress = contract_address_const::<
            0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a
        >();
        let oracle_dispatcher = IPragmaABIDispatcher { contract_address: oracle_address };
        let output: PragmaPricesResponse = oracle_dispatcher
            .get_data(asset, AggregationMode::Median(()));
        return output.price;
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
