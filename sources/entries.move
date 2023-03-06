module drand::entries {
    use sui::coin::Coin;
    use drand::chain::{DSUI, Chain};
    use sui::tx_context::TxContext;
    use drand::chain;
    use sui::transfer;
    use std::option;
    use sui::tx_context;

    public entry fun add(){}

    public entry fun redeem(chain: &mut Chain, debt: Coin<DSUI>, ctx: &mut TxContext) {
        let (opt_sui, opt_dsui) = chain::redeem(chain, debt, ctx);

        transfer::transfer(option::destroy_some(opt_sui), tx_context::sender(ctx));

        if (option::is_some(&opt_dsui)) {
            transfer::transfer(option::destroy_some(opt_dsui), tx_context::sender(ctx));
        } else {
            option::destroy_none(opt_dsui);
        };
    }
}