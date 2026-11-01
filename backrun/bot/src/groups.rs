//! Groups of cycles: one request (`solveMany`) per group. The builder runs the group's best plan.
//!
//! A group is a seed cycle and the later cycles that share a pool with the seed, up to
//! `group_size`. Cycles that share a pool compete for the same price move, and the builder
//! executes at most the best of them on it. One request for all of them uses one pending slot,
//! where separate requests would use several. `run.rs` sends the first `pending_budget() / request_copies` groups.
use crate::cycles::{Cycle, Leg};
use alloy::primitives::Address;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    /// `<seed name>+<N>`; a one-cycle group keeps the cycle's name (same uuid as a lone cycle).
    pub name: String,
    pub cycles: Vec<Cycle>,
}

impl Group {
    /// Copy `k` of this group's request (`request_copies`): copy 0 is the group itself, copy
    /// k >= 1 is named `<name>#k`, which keys its uuid and code target.
    pub fn copy(&self, k: usize) -> Group {
        Group {
            name: match k {
                0 => self.name.clone(),
                k => format!("{}#{k}", self.name),
            },
            cycles: self.cycles.clone(),
        }
    }
}

/// Pool identity for grouping: version, unordered token pair, fee, tick spacing.
fn pool(l: &Leg) -> (u8, Address, Address, u32, i32) {
    let (a, b) = if l.token_in <= l.token_out {
        (l.token_in, l.token_out)
    } else {
        (l.token_out, l.token_in)
    };
    (l.version, a, b, l.fee, l.tick_spacing)
}

pub fn shares_pool(a: &Cycle, b: &Cycle) -> bool {
    a.legs
        .iter()
        .any(|x| b.legs.iter().any(|y| pool(x) == pool(y)))
}

/// Multi-pass greedy in file order: the first ungrouped cycle seeds a group and takes every later
/// ungrouped cycle that shares a pool with the SEED, up to `size` members.
pub fn group_cycles(cycles: &[Cycle], size: usize) -> Vec<Group> {
    let mut taken = vec![false; cycles.len()];
    let mut out = Vec::new();
    for (i, seed) in cycles.iter().enumerate() {
        if taken[i] {
            continue;
        }
        let mut members = vec![seed.clone()];
        for (j, c) in cycles.iter().enumerate().skip(i + 1) {
            if members.len() >= size {
                break;
            }
            if !taken[j] && shares_pool(seed, c) {
                taken[j] = true;
                members.push(c.clone());
            }
        }
        let name = match members.len() {
            1 => seed.name.clone(),
            n => format!("{}+{n}", seed.name),
        };
        out.push(Group {
            name,
            cycles: members,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pool `p`: a V3 WETH/token-p pool with fee `p`.
    fn leg(p: u8) -> Leg {
        Leg {
            version: 3,
            token_in: Address::repeat_byte(0xee),
            token_out: Address::repeat_byte(p),
            fee: p.into(),
            tick_spacing: 1,
        }
    }

    fn cycle(name: &str, pools: &[u8]) -> Cycle {
        Cycle {
            name: name.into(),
            legs: pools.iter().map(|&p| leg(p)).collect(),
        }
    }

    fn names(gs: &[Group]) -> Vec<(String, Vec<String>)> {
        gs.iter()
            .map(|g| {
                let members = g.cycles.iter().map(|c| c.name.clone()).collect();
                (g.name.clone(), members)
            })
            .collect()
    }

    #[test]
    fn test_pool_identity_ignores_token_order() {
        let a = cycle("a", &[1]);
        let mut b = cycle("b", &[1]);
        let l = &mut b.legs[0];
        std::mem::swap(&mut l.token_in, &mut l.token_out);
        assert!(shares_pool(&a, &b));
        let mut c = cycle("c", &[1]);
        c.legs[0].tick_spacing = 10;
        assert!(!shares_pool(&a, &c), "tick spacing is part of the pool");
        let mut d = cycle("d", &[1]);
        d.legs[0].version = 4;
        assert!(!shares_pool(&a, &d), "version is part of the pool");
    }

    #[test]
    fn test_group_size_1_keeps_cycle_names() {
        let cs = vec![cycle("a", &[1, 2]), cycle("b", &[1, 3])];
        let gs = group_cycles(&cs, 1);
        assert_eq!(
            names(&gs),
            vec![
                ("a".into(), vec!["a".into()]),
                ("b".into(), vec!["b".into()])
            ]
        );
    }

    #[test]
    fn test_group_size_4_greedy_with_seed() {
        let cs = vec![
            cycle("A", &[1, 2]),
            cycle("B", &[2, 3]),
            cycle("C", &[4, 5]),
            cycle("D", &[1, 6]),
            cycle("E", &[1, 7]),
            cycle("F", &[1, 8]),
        ];
        let gs = group_cycles(&cs, 4);
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(
            names(&gs),
            vec![
                ("A+4".into(), s(&["A", "B", "D", "E"])),
                ("C".into(), s(&["C"])),
                ("F".into(), s(&["F"])),
            ]
        );
        assert_eq!(gs, group_cycles(&cs, 4), "deterministic");
    }

    #[test]
    fn test_sharing_is_with_the_seed_only() {
        // B shares pool 2 with A; C shares pool 3 with B only.
        let cs = vec![
            cycle("A", &[1, 2]),
            cycle("B", &[2, 3]),
            cycle("C", &[3, 4]),
        ];
        let gs = group_cycles(&cs, 4);
        assert_eq!(gs.len(), 2);
        assert_eq!(gs[0].name, "A+2");
        assert_eq!(gs[1].name, "C");
    }
}
