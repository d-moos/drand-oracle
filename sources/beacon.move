module drand::beacon {
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

    const EInvalidSignature: u64 = 1;

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
        period: u8
    }

    public entry fun create(
        public_key: vector<u8>,
        genesis_time: u64,
        period: u8,
        ctx: &mut TxContext
    ) {
        transfer::share_object(Chain {
            id: object::new(ctx),
            beacons: table::new(ctx),
            public_key,
            genesis_time,
            period
        });
    }

    public entry fun add(chain: &mut Chain, round: u64, signature: vector<u8>) {
        let previous_beacon = table::borrow(&chain.beacons, round - 1);

        verify(round, signature, previous_beacon, chain.public_key);

        table::add(&mut chain.beacons, round, Beacon {
            round, signature, previous_signature: previous_beacon.signature
        });
    }

    public fun get(chain: &Chain, round: u64): &Beacon {
        table::borrow(&chain.beacons, round)
    }

    fun verify(round: u64, signature: vector<u8>, previous_beacon: &Beacon, pubkey: vector<u8>) {
        // this is kinda given by the callee, yet we just re-check to be 100% sure
        assert!(round - 1 == previous_beacon.round, 0);

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