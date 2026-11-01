//! The gas price of profit: wei of profit the builder needs per unit of execute gas.
//!
//! `run` and `simulate` compute it once per head and send it as the solver's `weiPerGas`. The
//! solver prices the plan's gas and returns no plan below `weiPerGas * gas` (`NoProfit`), so the
//! builder never runs an execute that cannot pay for itself.
use crate::config::BotConfig;
use crate::head::Head;
use alloy::eips::eip1559::{calc_next_block_base_fee, BaseFeeParams};
use alloy::primitives::U256;

/// EIP-1559 base fee of block `h.number + 1`.
pub fn next_base_fee(h: &Head) -> u128 {
    if h.gas_limit < 2 {
        return h.base_fee as u128; // no gas target; alloy would divide by zero
    }
    calc_next_block_base_fee(
        h.gas_used,
        h.gas_limit,
        h.base_fee,
        BaseFeeParams::ethereum(),
    ) as u128
}

/// `ceil(next_base_fee * gas_margin_bps / builder_share_bps)`: wei of profit per unit of execute
/// gas. The builder gets `profit * builder_share_bps / 10000`, and that must cover the gas, so
/// the solver floors the plan's profit at `wei_per_gas * gas(plan)`. The f64 margin is converted
/// once to basis points (1.25 -> 12500).
pub fn wei_per_gas(cfg: &BotConfig, next_base_fee: u128) -> U256 {
    let margin_bps = (cfg.gas_margin * 10_000.0).round() as u64;
    let num = U256::from(next_base_fee) * U256::from(margin_bps);
    num.div_ceil(U256::from(cfg.builder_share_bps))
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::Address;

    const GWEI: u64 = 1_000_000_000;

    fn head(base_fee: u64, gas_used: u64) -> Head {
        Head {
            number: 1,
            base_fee,
            gas_used,
            gas_limit: 30_000_000,
            timestamp: 0,
        }
    }

    #[test]
    fn test_next_base_fee_vectors() {
        assert_eq!(next_base_fee(&head(10 * GWEI, 15_000_000)), 10_000_000_000);
        assert_eq!(next_base_fee(&head(10 * GWEI, 30_000_000)), 11_250_000_000);
        assert_eq!(next_base_fee(&head(10 * GWEI, 0)), 8_750_000_000);
    }

    #[test]
    fn test_next_base_fee_min_increase_is_one_wei() {
        assert_eq!(next_base_fee(&head(1, 30_000_000)), 2);
        assert_eq!(next_base_fee(&head(1, 0)), 1);
    }

    fn cfg(share: u16, margin: f64, min: u64) -> BotConfig {
        let t = format!(
            "endpoints = [\"http://localhost:1\"]\nrpc_http = \"http://localhost:2\"\n\
             solver = \"{a}\"\nexecutor = \"{a}\"\nweth = \"{a}\"\n\
             builder_share_bps = {share}\ngas_margin = {margin}\nmin_profit_wei = \"{min:#x}\"\n",
            a = Address::ZERO
        );
        toml::from_str(&t).unwrap()
    }

    #[test]
    fn test_wei_per_gas_uses_share_and_margin() {
        // 10 gwei, margin 1.25, share 10000 -> 12.5 gwei; share 5000 -> 25 gwei
        let bf = 10 * GWEI as u128;
        assert_eq!(
            wei_per_gas(&cfg(10_000, 1.25, 0), bf),
            U256::from(12_500_000_000u64)
        );
        assert_eq!(
            wei_per_gas(&cfg(5_000, 1.25, 0), bf),
            U256::from(25_000_000_000u64)
        );
    }

    #[test]
    fn test_wei_per_gas_rounds_up() {
        // base fee 1, margin 1.0, share 3 -> ceil(10000 / 3) = 3334
        assert_eq!(wei_per_gas(&cfg(3, 1.0, 0), 1), U256::from(3334u64));
    }
}
