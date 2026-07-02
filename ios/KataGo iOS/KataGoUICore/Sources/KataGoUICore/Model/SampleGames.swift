//
//  SampleGames.swift
//  KataGoUICore
//
//  The bundled sample game the tvOS library offers while the user's own games
//  have not synced (or do not exist): Shusaku's 1846 "Ear-Reddening Game" —
//  Yasuda (Honinbo) Shusaku (B, 4d) vs Inoue Gennan Inseki (W, 8d), B+2, a
//  public-domain historical record. Ships in Release (not a preview fixture).
//
//  The score-lead history is precomputed offline (one KataGo raw-net eval per
//  position, black-positive to match GameRecord.scoreLeads) and baked in so
//  the review screen's chart works without ever analyzing on another device.
//  Regenerate with the engine if the SGF ever changes; the final entry should
//  land near the historical +2 result.
//

import Foundation

public enum SampleGames {
    /// The complete 325-move record. RU[Japanese] is REQUIRED — `loadGame`
    /// reads rules via C++ `Sgf::getRulesOrFail`, which aborts (uncatchable)
    /// on an SGF without one. KM[0]: the historical game had no komi.
    public static let earReddeningSgf = "(;GM[1]FF[4]SZ[19]RU[Japanese]KM[0]PB[Yasuda Shusaku]BR[4d]PW[Inoue Gennan Inseki]WR[8d]DT[1846-09-11]RE[B+2];B[qd];W[dc];B[pq];W[oc];B[cp];W[cf];B[ep];W[qo];B[pe];W[np];B[po];W[pp];B[op];W[qp];B[oq];W[oo];B[pn];W[qq];B[nq];W[on];B[pm];W[om];B[pl];W[mp];B[mq];W[ol];B[pk];W[lq];B[lr];W[kr];B[lp];W[kq];B[qr];W[rr];B[rs];W[mr];B[nr];W[pr];B[ps];W[qs];B[no];W[mo];B[qr];W[rm];B[rl];W[qs];B[lo];W[mn];B[qr];W[qm];B[or];W[ql];B[qj];W[rj];B[ri];W[rk];B[ln];W[mm];B[qi];W[rq];B[jn];W[ls];B[ns];W[gq];B[go];W[ck];B[kc];W[ic];B[pc];W[nj];B[ke];W[og];B[oh];W[pb];B[qb];W[ng];B[mi];W[mj];B[nd];W[ph];B[qg];W[pg];B[hq];W[hr];B[ir];W[iq];B[hp];W[jr];B[fc];W[lc];B[ld];W[mc];B[lb];W[mb];B[md];W[qf];B[pf];W[qh];B[rg];W[rh];B[sh];W[rf];B[sg];W[pj];B[pi];W[oi];B[oj];W[ni];B[qk];W[ok];B[qe];W[kb];B[jb];W[ka];B[jc];W[ob];B[ja];W[la];B[db];W[cc];B[fe];W[cn];B[gr];W[is];B[fq];W[io];B[ji];W[eb];B[fb];W[eg];B[dj];W[dk];B[ej];W[cj];B[dh];W[ij];B[hm];W[gj];B[eh];W[fl];B[fg];W[er];B[dm];W[fn];B[dn];W[gn];B[jj];W[jk];B[kk];W[ii];B[ik];W[jl];B[kl];W[il];B[jh];W[co];B[do];W[ih];B[hn];W[hl];B[bl];W[dg];B[gh];W[ch];B[ig];W[ec];B[cr];W[fd];B[gd];W[ed];B[gc];W[bk];B[cm];W[gs];B[gp];W[li];B[kg];W[in];B[lj];W[lg];B[gm];W[jf];B[jg];W[im];B[fm];W[kf];B[lf];W[mf];B[le];W[gf];B[hf];W[ff];B[gg];W[lk];B[kj];W[km];B[lm];W[ll];B[jm];W[ge];B[he];W[ef];B[ea];W[cb];B[fr];W[fs];B[dr];W[qa];B[ra];W[pa];B[rb];W[da];B[gi];W[fj];B[fi];W[fa];B[ga];W[gl];B[ek];W[em];B[ho];W[el];B[en];W[jo];B[kn];W[ci];B[lh];W[mh];B[mg];W[di];B[ei];W[lg];B[qn];W[rn];B[re];W[sl];B[mg];W[bm];B[am];W[lg];B[eq];W[es];B[mg];W[ha];B[gb];W[lg];B[ds];W[hs];B[mg];W[sj];B[si];W[lg];B[sr];W[sq];B[mg];W[hd];B[hb];W[lg];B[ro];W[so];B[mg];W[ss];B[qs];W[lg];B[sn];W[rp];B[mg];W[cl];B[bn];W[lg];B[ml];W[mk];B[mg];W[pj];B[sf];W[lg];B[nn];W[nl];B[mg];W[ib];B[ia];W[lg];B[nc];W[nb];B[mg];W[jd];B[kd];W[lg];B[ma];W[na];B[mg];W[qc];B[rc];W[lg];B[js];W[ks];B[mg];W[hc];B[id];W[lg];B[fk];W[hj];B[mg];W[hh];B[hg];W[lg];B[gk];W[hk];B[mg];W[ak];B[lg];W[al];B[bm];W[nf];B[od];W[ki];B[ms];W[kp];B[ip];W[jp];B[lr];W[oj];B[mr];W[ea];B[sr])"

    /// Black's score lead after each move 0...325, from a single KataGo
    /// raw-net eval per position under Japanese rules, komi 0. Index == move
    /// count, matching how live analysis fills `GameRecord.scoreLeads`.
    public static let earReddeningScoreLeads: [Int: Float] = {
        let leads: [Float] = [
        5.4, 7.6, 6.0, 6.3, 7.0, 6.4, 6.8, 6.9, 6.5, 6.9,
        6.8, 7.9, 7.2, 8.0, 8.0, 7.8, 7.4, 7.4, 8.0, 7.3,
        7.1, 7.1, 6.8, 6.4, 7.4, 6.4, 6.0, 6.8, 5.6, 5.2,
        4.6, 1.6, 1.9, 1.5, 2.5, 1.6, 3.5, 2.8, 2.6, 4.2,
        3.3, 4.1, 3.7, 3.7, 4.0, 2.6, 2.6, -0.1, 1.0, 1.9,
        3.8, 2.8, 2.1, 1.7, 1.1, 2.1, 1.8, 1.2, 1.9, 0.4,
        5.7, 3.4, 4.9, 3.8, 5.2, 3.7, 4.9, 3.8, 5.4, 3.0,
        3.2, 2.7, 2.5, 2.4, 2.4, 2.5, 3.1, 4.2, 4.8, 2.2,
        3.3, 3.4, 3.9, 4.0, 5.5, 5.5, 5.6, 6.4, 6.5, 5.8,
        7.6, 6.6, 11.1, 7.6, 12.4, 6.0, 5.2, 2.6, 1.4, 2.6,
        0.4, 2.4, 0.2, 1.6, 0.4, 2.5, 0.3, 3.8, -0.8, 1.3,
        -0.4, 0.5, -0.7, 1.1, 0.4, 0.6, 0.6, 0.0, 0.6, -0.6,
        -0.1, -1.8, -0.9, -0.3, -0.8, -0.7, 0.6, -0.1, -0.0, -0.2,
        0.6, 0.4, 0.5, 0.5, 0.6, 1.0, 1.6, 1.1, 1.3, 1.4,
        1.4, 1.7, 4.4, 3.4, 4.6, 5.2, 4.8, 4.2, 4.5, 5.7,
        6.6, 5.9, 6.3, 4.7, 3.5, 3.0, 2.8, 2.8, 5.1, 4.8,
        5.2, 4.1, 6.3, 4.2, 3.7, 3.2, 3.7, 3.6, 4.4, 4.1,
        4.9, 4.7, 6.5, 5.7, 5.9, 3.5, 3.4, 4.2, 3.7, 3.9,
        3.8, 3.8, 3.8, 4.3, 4.8, 4.4, 6.1, 6.2, 6.8, 6.4,
        7.9, 2.9, 2.0, 1.7, 2.4, 1.4, 3.0, 1.9, 2.7, 1.6,
        1.4, 1.6, 1.7, 1.4, 1.3, 0.3, 0.1, 0.0, 0.4, 0.2,
        0.4, 0.0, 0.2, -0.3, 0.1, -0.3, -0.4, -0.5, -0.0, -0.6,
        -0.1, -0.5, -0.0, -0.5, -0.3, -0.4, -0.1, -0.7, -0.1, -1.0,
        0.2, -0.4, 0.1, -0.7, -0.3, -1.2, 0.1, -0.8, 0.4, -0.4,
        0.3, -0.7, 0.5, -0.5, 0.3, -0.6, 0.2, -0.6, 0.0, -0.7,
        0.3, -0.5, 0.1, -0.7, 0.2, -0.3, 0.4, 0.4, 0.8, 0.7,
        1.1, 0.6, 1.0, 0.9, 1.1, 1.3, 1.3, 0.6, 1.3, 1.1,
        1.2, 1.2, 1.2, 0.9, 1.0, 1.2, 1.1, 1.3, 1.4, 1.0,
        1.0, 0.9, 1.1, 1.3, 1.1, 1.0, 0.8, 1.2, 1.0, 1.1,
        1.1, 0.8, 0.8, 0.9, 0.9, 0.9, 0.9, 0.7, 0.4, 0.6,
        0.7, 0.6, 1.1, 0.9, 0.9, 1.2, 1.1, 1.3, 1.2, 1.2,
        1.3, 1.6, 1.6, 1.6, 1.8, 2.1, 1.6, 2.0, 1.6, 2.1,
        1.8, 1.8, 2.0, 2.2, 2.2, 2.1
        ]
        return Dictionary(uniqueKeysWithValues: leads.enumerated().map { ($0.offset, $0.element) })
    }()

    /// Builds a fresh sample record. The caller owns keeping it OUT of the
    /// CloudKit-synced store (insert into an in-memory container only) —
    /// opening a game mutates its record, and those writes must never sync.
    @MainActor
    public static func makeEarReddeningRecord() -> GameRecord {
        let sgfHelper = SgfOperations(sgf: earReddeningSgf)
        let moveSize = sgfHelper.moveSize ?? 0

        // Final position at the last move index so the library card can draw
        // the finished game (the importGameRecord pattern); currentIndex stays
        // 0 so review starts at the opening.
        let finalStones = sgfHelper.finalStones()
        let blackStones: [Int: String] = [moveSize: finalStones.black.joined(separator: " ")]
        let whiteStones: [Int: String] = [moveSize: finalStones.white.joined(separator: " ")]

        let record = GameRecord.createGameRecord(sgf: earReddeningSgf,
                                                 currentIndex: 0,
                                                 name: "Ear-Reddening Game",
                                                 scoreLeads: earReddeningScoreLeads,
                                                 blackStones: blackStones,
                                                 whiteStones: whiteStones)
        // createGameRecord derives board size and komi from the SGF but not
        // the rule index; without this the 1846 game would display — and be
        // analyzed under — the default Chinese rules instead of RU[Japanese].
        if let japanese = Config.rules.firstIndex(of: "japanese") {
            record.concreteConfig.rule = japanese
        }
        // 1846-09-11 — renders as the card's date line and keeps the sample
        // sorted far below any real game if it ever shares a list.
        record.lastModificationDate = Date(timeIntervalSince1970: -3891196800)
        return record
    }
}
