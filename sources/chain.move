module drand::chain {
    use sui::object::UID;
    use sui::table::Table;
    use sui::table;
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::object;
    use std::hash::sha2_256;
    use std::bcs;
    use sui::bls12381::bls12381_min_pk_verify;
    use std::vector;
    use sui::clock::Clock;
    use sui::clock;
    use sui::coin::{create_currency, TreasuryCap, Coin};
    use std::option;
    use sui::balance::Balance;
    use sui::sui::SUI;
    use sui::balance;
    use sui::coin;
    use sui::tx_context;
    use std::option::Option;

    // chain does currently not have any SUI
    const EInsufficientBalance: u64 = 3;

    // callee did not provide enough SUI
    const EInsufficientCredits: u64 = 2;

    const EInvalidSignature: u64 = 1;
    const EInvalidRound: u64 = 0;

    const AddBeaconReward: u64 = 1;
    const GetBeaconPrice: u64 = 1;

    struct Beacon has store, drop {
        round: u64,
        previous_signature: vector<u8>,
        signature: vector<u8>
    }

    struct Chain has store, key {
        id: UID,
        public_key: vector<u8>,
        beacons: Table<u64, Beacon>,
        genesis_time: u64,
        latest_round: u64,
        period: u8,

        debt_treasury: TreasuryCap<DSUI>,
        sui_balance: Balance<SUI>
    }

    struct DSUI has drop {}

    fun init(ctx: &mut TxContext) {
        let loe_public_key = x"868f005eb8e6e4ca0a47c8a77ceaa5309a47978a7c71bc5cce96366b5d7a569937c529eeda66c7293784a9402801af31";
        let loe_period = 30u8;
        let loe_genesis_time = 1595431050u64;

        let initial_round = 2755456u64;
        let initial_signature = x"8afdf9a54756cc672832475b7722c2cd57bb6ccd9cb044473338371215c60917a0e9d95b16024bd686d49e9ddc9bc9dd08525e716274a19525d353894f19179c6c3827df82f97f08214cff8515a294481eb1e6cd4bdcea4be07f08e230429df6";

        let treasury = create_debt_coin(ctx);

        transfer::share_object(create(
            loe_public_key,
            loe_genesis_time,
            loe_period,
            initial_round,
            initial_signature,
            treasury,
            ctx
        ));
    }

    fun create_debt_coin(ctx: &mut TxContext): TreasuryCap<DSUI> {
        let (cap, metadata) = create_currency(
            DSUI {},
            9,
            b"DSUI",
            b"drand SUI Debt",
            b"",
            option::none(),
            ctx
        );

        transfer::share_object(metadata);

        cap
    }

    fun create(
        public_key: vector<u8>,
        genesis_time: u64,
        period: u8,
        initial_round: u64,
        initial_signature: vector<u8>,
        treasury: TreasuryCap<DSUI>,
        ctx: &mut TxContext
    ): Chain {
        let chain = Chain {
            id: object::new(ctx),
            beacons: table::new(ctx),
            public_key,
            genesis_time,
            latest_round: initial_round,
            period,
            debt_treasury: treasury,
            sui_balance: balance::zero()
        };

        let initial_beacon = Beacon {
            signature: initial_signature,
            previous_signature: vector::empty(),
            round: initial_round
        };

        table::add(&mut chain.beacons, initial_round, initial_beacon);

        chain
    }

    public fun add(chain: &mut Chain, signature: vector<u8>, ctx: &mut TxContext) {
        let previous_beacon = table::borrow(&chain.beacons, chain.latest_round);

        verify(chain.latest_round + 1, signature, previous_beacon, chain.public_key);

        table::add(&mut chain.beacons, chain.latest_round + 1, Beacon {
            round: chain.latest_round + 1, signature, previous_signature: previous_beacon.signature
        });

        chain.latest_round = chain.latest_round + 1;

        coin::mint_and_transfer(&mut chain.debt_treasury, AddBeaconReward, tx_context::sender(ctx), ctx);
    }

    public fun redeem(chain: &mut Chain, debt: Coin<DSUI>, ctx: &mut TxContext): (Option<Coin<SUI>>, Option<Coin<DSUI>>) {
        assert!(balance::value(&chain.sui_balance) > 0, EInsufficientBalance);

        let sui_balance = balance::value(&chain.sui_balance);
        let coin_value = coin::value(&debt);

        let sui_option = option::none<Coin<SUI>>();
        let dsui_option = option::none<Coin<DSUI>>();

        if (coin_value > sui_balance) {
            let remainder_coin = coin::split(&mut debt, sui_balance, ctx);
            coin::burn(&mut chain.debt_treasury, remainder_coin);
            option::fill(&mut dsui_option, debt);

            let credit_balance = balance::split(&mut chain.sui_balance, sui_balance);
            option::fill(&mut sui_option, coin::from_balance(credit_balance, ctx));
        } else if (coin_value == sui_balance) {
            coin::burn(&mut chain.debt_treasury, debt);

            let credit_balance = balance::split(&mut chain.sui_balance, sui_balance);
            option::fill(&mut sui_option, coin::from_balance(credit_balance, ctx));
        } else {
            coin::burn(&mut chain.debt_treasury, debt);

            let credit_balance = balance::split(&mut chain.sui_balance, sui_balance - coin_value);
            option::fill(&mut sui_option, coin::from_balance(credit_balance, ctx));
        };

        (sui_option, dsui_option)
    }

    public fun current_round(chain: &Chain, clock: &Clock): u64 {
        (clock::timestamp_ms(clock) - chain.genesis_time) / (chain.period as u64)
    }

    public fun latest_round(chain: &Chain): u64 {
        chain.latest_round
    }

    public fun latest(chain: &mut Chain, payment: Coin<SUI>, ctx: &mut TxContext): &Beacon {
        let latest_round = chain.latest_round;
        get(chain, latest_round, payment, ctx)
    }

    public fun get(chain: &mut Chain, round: u64, payment: Coin<SUI>, ctx: &mut TxContext): &Beacon {
        accept_payment(chain, payment, ctx);

        table::borrow(&chain.beacons, round)
    }

    fun accept_payment(chain: &mut Chain, payment: Coin<SUI>, ctx: &mut TxContext) {
        assert!(coin::value(&payment) >= GetBeaconPrice, EInsufficientCredits);

        let payment_balance = coin::into_balance(payment);
        let remainder = balance::value(&payment_balance) - GetBeaconPrice;

        if (remainder > 0) {
            let remainder_balance = balance::split(&mut payment_balance, remainder);
            transfer::transfer(
                coin::from_balance(remainder_balance, ctx),
                tx_context::sender(ctx)
            );
        };

        balance::join(&mut chain.sui_balance, payment_balance);
    }

    fun verify(round: u64, signature: vector<u8>, previous_beacon: &Beacon, pubkey: vector<u8>) {
        assert!(round - 1 == previous_beacon.round, EInvalidRound);

        let message = create_message(&previous_beacon.signature, round);

        let signature_is_valid = bls12381_min_pk_verify(
            &signature,
            &pubkey,
            &message
        );

        assert!(signature_is_valid, EInvalidSignature);
    }

    fun create_message(previous_signature: &vector<u8>, round: u64): vector<u8> {
        let round_bytes = bcs::to_bytes(&round);
        vector::reverse(&mut round_bytes);

        let buffer = vector::empty<u8>();
        vector::append(&mut buffer, *previous_signature);
        vector::append(&mut buffer, round_bytes);

        sha2_256(buffer)
    }

    #[test]
    fun verify_test() {
        let pk_leo_mainnet = x"868f005eb8e6e4ca0a47c8a77ceaa5309a47978a7c71bc5cce96366b5d7a569937c529eeda66c7293784a9402801af31";
        let previous_signature = x"a609e19a03c2fcc559e8dae14900aaefe517cb55c840f6e69bc8e4f66c8d18e8a609685d9917efbfb0c37f058c2de88f13d297c7e19e0ab24813079efe57a182554ff054c7638153f9b26a60e7111f71a0ff63d9571704905d3ca6df0b031747";
        let signature = x"82f5d3d2de4db19d40a6980e8aa37842a0e55d1df06bd68bddc8d60002e8e959eb9cfa368b3c1b77d18f02a54fe047b80f0989315f83b12a74fd8679c4f12aae86eaf6ab5690b34f1fddd50ee3cc6f6cdf59e95526d5a5d82aaa84fa6f181e42";
        let round: u64 = 72785;

        let previous_beacon = Beacon {
            round: 72784,
            signature: previous_signature,
            previous_signature: vector::empty()
        };

        verify(
            round,
            signature,
            &previous_beacon,
            pk_leo_mainnet
        );
    }
}