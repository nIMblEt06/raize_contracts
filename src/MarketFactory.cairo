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
    deadline: u64,
    money_in_pool: u256,
    winning_outcome: Option<Outcome>,
    conditions: Option<
        u8
    >, // 0 -> less than amount, 1 -> greater than amount. e.g.(0) -> will BTC go below $40,000?
    price_key: Option<felt252>,
    amount: Option<u128>,
    api_event_id: Option<
        u64
    >, // the settling market script will send an API request on the event id to fetch the results from the event, and settles the market accordingly
    is_home: Option<bool>,
}

#[derive(Copy, Serde, Drop, starknet::Store, PartialEq, Eq, Hash)]
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
        deadline: u64,
    );

    fn create_sports_market(
        ref self: TContractState,
        name: ByteArray,
        description: ByteArray,
        outcomes: (felt252, felt252),
        category: felt252,
        image: ByteArray,
        deadline: u64,
        api_event_id: u64,
        is_home: bool,
    );

    fn create_crypto_market(
        ref self: TContractState,
        name: ByteArray,
        description: ByteArray,
        outcomes: (felt252, felt252),
        category: felt252,
        image: ByteArray,
        deadline: u64,
        conditions: u8,
        price_key: felt252,
        amount: u128,
    );

    fn get_market_count(self: @TContractState) -> u256;

    fn buy_shares(
        ref self: TContractState, market_id: u256, token_to_mint: u8, amount: u256
    ) -> bool;

    fn settle_market(ref self: TContractState, market_id: u256, winning_outcome: u8);

    fn claim_winnings(ref self: TContractState, market_id: u256, bet_num: u8);

    fn get_market(self: @TContractState, market_id: u256) -> Market;

    fn get_all_markets(self: @TContractState) -> Array<Market>;

    fn get_user_markets(self: @TContractState, user: ContractAddress) -> Array<Market>;

    fn get_owner(self: @TContractState) -> ContractAddress;

    fn get_treasury_wallet(self: @TContractState) -> ContractAddress;

    fn set_treasury_wallet(ref self: TContractState, wallet: ContractAddress);

    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);

    fn get_num_bets_in_market(self: @TContractState, user: ContractAddress, market_id: u256) -> u8;

    fn get_outcome_and_bet(
        self: @TContractState, user: ContractAddress, market_id: u256, bet_num: u8
    ) -> UserBet;

    fn get_user_total_claimable(self: @TContractState, user: ContractAddress) -> u256;

    fn toggle_market(ref self: TContractState, market_id: u256);

    fn settle_crypto_market(ref self: TContractState, market_id: u256);

    fn add_admin(ref self: TContractState, admin: ContractAddress);

    fn remove_all_markets(ref self: TContractState);

    fn set_platform_fee(ref self: TContractState, fee: u256);

    fn get_platform_fee(self: @TContractState) -> u256;
}

#[starknet::contract]
pub mod MarketFactory {
    use openzeppelin::token::erc20::interface::IERC20DispatcherTrait;
    use core::array::ArrayTrait;
    use super::{Market, Outcome, UserPosition, UserBet};
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_contract_address,
        contract_address_const, get_block_timestamp
    };
    use openzeppelin::token::erc20::interface::IERC20Dispatcher;
    use starknet::SyscallResultTrait;
    use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use pragma_lib::types::{AggregationMode, DataType, PragmaPricesResponse};
    const one: u256 = 1_000_000_000_000_000_000;

    #[storage]
    struct Storage {
        user_bet: LegacyMap::<(ContractAddress, u256, u8), UserBet>,
        num_bets: LegacyMap::<(ContractAddress, u256), u8>,
        markets: LegacyMap::<u256, Market>,
        idx: u256,
        owner: ContractAddress,
        treasury_wallet: ContractAddress,
        admins: LegacyMap::<u128, ContractAddress>,
        num_admins: u128,
        platform_fee: u256
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
            deadline: u64,
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
                conditions: Option::None,
                price_key: Option::None,
                amount: Option::None,
                api_event_id: Option::None,
                is_home: Option::None,
            };
            self.idx.write(self.idx.read() + 1);
            self.markets.write(self.idx.read(), market);
            let current_market = self.markets.read(self.idx.read());
            self.emit(MarketCreated { market: current_market });
        }
        fn create_crypto_market(
            ref self: ContractState,
            name: ByteArray,
            description: ByteArray,
            outcomes: (felt252, felt252),
            category: felt252,
            image: ByteArray,
            deadline: u64,
            conditions: u8,
            price_key: felt252,
            amount: u128,
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
                api_event_id: Option::None,
                is_home: Option::None,
                conditions: Option::Some(conditions),
                price_key: Option::Some(price_key),
                amount: Option::Some(amount),
            };
            self.idx.write(self.idx.read() + 1);
            self.markets.write(self.idx.read(), market);
            let current_market = self.markets.read(self.idx.read());
            self.emit(MarketCreated { market: current_market });
        }


        fn get_market(self: @ContractState, market_id: u256) -> Market {
            return self.markets.read(market_id);
        }

        fn create_sports_market(
            ref self: ContractState,
            name: ByteArray,
            description: ByteArray,
            outcomes: (felt252, felt252),
            category: felt252,
            image: ByteArray,
            deadline: u64,
            api_event_id: u64,
            is_home: bool,
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
            let sports_market = Market {
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
                api_event_id: Option::Some(api_event_id),
                is_home: Option::Some(is_home),
                conditions: Option::None,
                price_key: Option::None,
                amount: Option::None,
            };
            self.idx.write(self.idx.read() + 1);
            self.markets.write(self.idx.read(), sports_market);
            let current_market = self.markets.read(self.idx.read());
            self.emit(MarketCreated { market: current_market });
        }

        fn get_market_count(self: @ContractState) -> u256 {
            return self.idx.read();
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

        fn get_user_markets(self: @ContractState, user: ContractAddress) -> Array<Market> {
            let mut markets: Array<Market> = ArrayTrait::new();
            let mut i: u256 = 1;
            loop {
                if i > self.idx.read() {
                    break;
                }
                let total_bets = self.num_bets.read((user, i));
                if total_bets > 0 {
                    markets.append(self.markets.read(i));
                }
                i += 1;
            };
            markets
        }

        fn get_num_bets_in_market(
            self: @ContractState, user: ContractAddress, market_id: u256
        ) -> u8 {
            return self.num_bets.read((user, market_id));
        }

        fn settle_crypto_market(ref self: ContractState, market_id: u256) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can settle markets.');
            assert(market_id <= self.idx.read(), 'Market does not exist');
            let mut market = self.markets.read(market_id);
            let price = get_asset_price_median(DataType::SpotEntry(market.price_key.unwrap()));
            market.is_settled = true;
            market.is_active = false;
            let (outcome1, outcome2) = market.outcomes;
            if market.conditions.unwrap() == 0 {
                if price < market.amount.unwrap() {
                    market.winning_outcome = Option::Some(outcome1);
                } else {
                    market.winning_outcome = Option::Some(outcome2);
                }
            } else {
                if price > market.amount.unwrap() {
                    market.winning_outcome = Option::Some(outcome1);
                } else {
                    market.winning_outcome = Option::Some(outcome2);
                }
            }
            self.markets.write(market_id, market);
            let current_market = self.markets.read(market_id);
            self.emit(MarketSettled { market: current_market });
        }

        fn toggle_market(ref self: ContractState, market_id: u256) {
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
            let mut market = self.markets.read(market_id);
            market.is_active = !market.is_active;
            self.markets.write(market_id, market);
            let current_market = self.markets.read(market_id);
            self.emit(MarketToggled { market: current_market });
        }
        
        fn set_platform_fee(ref self: ContractState, fee: u256) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can set.');
            self.platform_fee.write(fee);
        }

        fn get_platform_fee(self: @ContractState) -> u256 {
            return self.platform_fee.read();
        }

        fn get_outcome_and_bet(
            self: @ContractState, user: ContractAddress, market_id: u256, bet_num: u8
        ) -> UserBet {
            let user_bet = self.user_bet.read((user, market_id, bet_num));
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
                if market.is_settled == false {
                    i += 1;
                    continue;
                }
                let total_bets = self.num_bets.read((user, i));
                if total_bets > 0 {
                    let mut bet_num = 1;
                    loop {
                        if bet_num > total_bets {
                            break;
                        }
                        let user_bet = self.user_bet.read((user, i, bet_num));
                        if user_bet.outcome.name == market.winning_outcome.unwrap().name {
                            if user_bet.position.has_claimed == false {
                                total += user_bet.position.amount
                                    * market.money_in_pool
                                    / market.winning_outcome.unwrap().bought_shares;
                            }
                        }
                        bet_num += 1;
                    }
                }
                i += 1;
            };
            total
        }

        // creates a position in a market for a user
        fn buy_shares(
            ref self: ContractState, market_id: u256, token_to_mint: u8, amount: u256,
        ) -> bool {
            let usdc_address = contract_address_const::<
            0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            >();
            let dispatcher = IERC20Dispatcher { contract_address: usdc_address };
            let mut market = self.markets.read(market_id);
            assert(market.is_active, 'Market not active.');
            assert(get_block_timestamp() < market.deadline, 'Market has expired.');
            let (mut outcome1, mut outcome2) = market.outcomes;

            let txn: bool = dispatcher
                .transfer_from(get_caller_address(), get_contract_address(), amount);
            dispatcher.transfer(self.treasury_wallet.read(), amount * self.platform_fee.read() / 100);

            let bought_shares = amount - amount * self.platform_fee.read() / 100;
            let money_in_pool = market.money_in_pool + bought_shares;

            if token_to_mint == 0 {
                outcome1.bought_shares += bought_shares;
            } else {
                outcome2.bought_shares += bought_shares;
            }

            market.outcomes = (outcome1, outcome2);
            market.money_in_pool = money_in_pool;

            self.markets.write(market_id, market);
            self
                .num_bets
                .write(
                    (get_caller_address(), market_id),
                    self.num_bets.read((get_caller_address(), market_id)) + 1
                );
            self
                .user_bet
                .write(
                    (
                        get_caller_address(),
                        market_id,
                        self.num_bets.read((get_caller_address(), market_id))
                    ),
                    UserBet {
                        outcome: if token_to_mint == 0 {
                            outcome1
                        } else {
                            outcome2
                        },
                        position: UserPosition { amount: amount, has_claimed: false }
                    }
                );
            let new_market = self.markets.read(market_id);
            self
                .emit(
                    ShareBought {
                        user: get_caller_address(),
                        market: new_market,
                        outcome: if token_to_mint == 0 {
                            outcome1
                        } else {
                            outcome2
                        },
                        amount: amount
                    }
                );
            txn
        }

        fn remove_all_markets(ref self: ContractState) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can remove markets.');
            self.idx.write(0);
        }

        fn get_treasury_wallet(self: @ContractState) -> ContractAddress {
            assert(get_caller_address() == self.owner.read(), 'Only owner can read.');
            return self.treasury_wallet.read();
        }

        fn claim_winnings(ref self: ContractState, market_id: u256, bet_num: u8) {
            assert(market_id <= self.idx.read(), 'Market does not exist');
            let mut winnings = 0;
            let market = self.markets.read(market_id);
            assert(market.is_settled == true, 'Market not settled');
            let user_bet: UserBet = self.user_bet.read((get_caller_address(), market_id, bet_num));
            assert(user_bet.position.has_claimed == false, 'User has claimed winnings.');
            let winning_outcome = market.winning_outcome.unwrap();
            assert(user_bet.outcome.name == winning_outcome.name, 'User did not win!');
            winnings = user_bet.position.amount
                * market.money_in_pool
                / winning_outcome.bought_shares;
            let usdc_address = contract_address_const::<
            0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            >();
            let dispatcher = IERC20Dispatcher { contract_address: usdc_address };
            dispatcher.transfer(get_caller_address(), winnings);
            self
                .user_bet
                .write(
                    (get_caller_address(), market_id, bet_num),
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
            let mut i = 1;
            loop {
                if i > self.num_admins.read() {
                    panic!("Only admins can settle markets.");
                }
                if self.admins.read(i) == get_caller_address() {
                    break;
                }
                i += 1;
            };
            assert(market_id <= self.idx.read(), 'Market does not exist');
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

        fn get_owner(self: @ContractState) -> ContractAddress {
            return self.owner.read();
        }

        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can upgrade.');
            starknet::syscalls::replace_class_syscall(new_class_hash).unwrap_syscall();
            self.emit(Upgraded { class_hash: new_class_hash });
        }
    }

    fn get_asset_price_median(asset: DataType) -> u128 {
        let oracle_address: ContractAddress = contract_address_const::<
            0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b
        >();
        let oracle_dispatcher = IPragmaABIDispatcher { contract_address: oracle_address };
        let output: PragmaPricesResponse = oracle_dispatcher
            .get_data(asset, AggregationMode::Median(()));
        return output.price;
    }
}
