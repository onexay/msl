#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jumps_land_where_the_comments_say() {
        let p = program(3);
        assert_eq!(p.len(), 20);
        let target = |i: usize| (i as i64 + 1 + p[i].off as i64) as usize;
        assert_eq!(target(2), 7); // listen
        assert_eq!(target(3), 18); // out
        assert_eq!(target(5), 18); // out
        assert_eq!(target(6), 10); // emit
        assert_eq!(p[11].regs, 1 | 1 << 4); // ld_imm64 r1, BPF_PSEUDO_MAP_FD
        assert_eq!(p[11].imm, 3);
        assert_eq!((p[19].code, p[18].imm), (0x95, 1));
        assert_eq!(std::mem::size_of::<Insn>(), 8);
    }
}
