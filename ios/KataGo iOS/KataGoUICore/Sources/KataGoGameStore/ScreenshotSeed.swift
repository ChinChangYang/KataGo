//
//  ScreenshotSeed.swift
//  KataGoGameStore
//
//  The single identity every platform's README-screenshot seed shares: the
//  launch argument that switches seeding on, the fixed record UUID, the record
//  name, the SGF, the display index, and the readiness marker the capture
//  script polls for instead of sleeping.
//
//  WHY IT LIVES IN KataGoGameStore. The watch app links only KataGoGameStore
//  and GoRulesKit (CLAUDE.md), so a constant declared in KataGoUICore — or in
//  any app target — would be invisible to it, and the watch has to seed and
//  open the very same game as everybody else. The SGF itself moved here from
//  `SampleGames.earReddeningSgf` for exactly that reason; `SampleGames` keeps
//  a forwarding alias so `SampleGamesTests`, `TVSampleGameStore` and every
//  other existing caller compile unchanged.
//
//  WHY IT IS NOT WRAPPED IN `#if DEBUG`. `SampleGames` ships in RELEASE (the
//  tvOS library offers the sample game), and it forwards to `sgf` here, so the
//  constants must compile in Release too. The BEHAVIOUR is DEBUG-only twice
//  over: `isActive` is hard-wired `false` outside DEBUG, and every call site is
//  additionally guarded — so a release build can be handed the launch argument
//  and will do nothing at all.
//
//  Nothing here is a test fixture in the SwiftPM sense. It is committed
//  tooling, driven by `Screenshots/capture_screenshots.sh`.
//

import Foundation
import SwiftData

public enum ScreenshotSeed {
    /// Pass to `simctl launch` (or `XCUIApplication.launchArguments`) to seed
    /// and open the README-screenshot game. One argument for every platform, so
    /// the capture script has one spelling to remember.
    public static let launchArgument = "--screenshot-seed"

    /// Fixed identity, so a re-run on a persisted simulator finds the same
    /// record instead of inserting a second one — and so the capture script can
    /// deep-link to it (`katago-anytime://open-game?id=...`) on the platforms
    /// that open by URL (watchOS, visionOS).
    public static let uuid = UUID(uuidString: "0000A11F-0000-0000-0000-00000000C0DE")!

    /// Distinctive on purpose. Together with the fixed UUID it makes a stray
    /// seed obvious if one ever reaches a real library — which is why the
    /// capture script insists the simulators are signed out of iCloud, the Mac
    /// seeds a DRAFT (never inserted), and tvOS seeds into its private
    /// in-memory container.
    public static let recordName = "Ear-Reddening Game"  // short enough for the iPhone title bar; the fixed UUID is the identity

    /// The position every platform's screenshot shows: after Black's move 127,
    /// the ear-reddening move itself. One position across five devices is the
    /// whole point of the seed — the README's images read as one product.
    public static let displayIndex = 127

    /// The `RU[]` token this record is played under. Beside the SGF so the two
    /// cannot drift: `seed(into:)` turns it into a `Config.rules` index without
    /// the C++ parser, which the watch cannot link.
    static let ruleToken = "japanese"

    /// Shusaku's 1846 "Ear-Reddening Game" — Yasuda (Honinbo) Shusaku (B, 4d)
    /// vs Inoue Gennan Inseki (W, 8d), B+2, a public-domain historical record.
    ///
    /// Keep `RU[Japanese]`: `loadGame` re-derives the rules from the SGF through
    /// the bridge's `SgfCpp::getRules`, which catches `getRulesOrFail` into an
    /// ALL-DEFAULT rule set with komi 7.0 when there is no rules tag — so
    /// without it this game would replay under Chinese-ish defaults and lose its
    /// `KM[0]`. `KM[0]`: the historical game had no komi.
    public static let sgf = "(;GM[1]FF[4]SZ[19]RU[Japanese]KM[0]PB[Yasuda Shusaku]BR[4d]PW[Inoue Gennan Inseki]WR[8d]DT[1846-09-11]RE[B+2];B[qd];W[dc];B[pq];W[oc];B[cp];W[cf];B[ep];W[qo];B[pe];W[np];B[po];W[pp];B[op];W[qp];B[oq];W[oo];B[pn];W[qq];B[nq];W[on];B[pm];W[om];B[pl];W[mp];B[mq];W[ol];B[pk];W[lq];B[lr];W[kr];B[lp];W[kq];B[qr];W[rr];B[rs];W[mr];B[nr];W[pr];B[ps];W[qs];B[no];W[mo];B[qr];W[rm];B[rl];W[qs];B[lo];W[mn];B[qr];W[qm];B[or];W[ql];B[qj];W[rj];B[ri];W[rk];B[ln];W[mm];B[qi];W[rq];B[jn];W[ls];B[ns];W[gq];B[go];W[ck];B[kc];W[ic];B[pc];W[nj];B[ke];W[og];B[oh];W[pb];B[qb];W[ng];B[mi];W[mj];B[nd];W[ph];B[qg];W[pg];B[hq];W[hr];B[ir];W[iq];B[hp];W[jr];B[fc];W[lc];B[ld];W[mc];B[lb];W[mb];B[md];W[qf];B[pf];W[qh];B[rg];W[rh];B[sh];W[rf];B[sg];W[pj];B[pi];W[oi];B[oj];W[ni];B[qk];W[ok];B[qe];W[kb];B[jb];W[ka];B[jc];W[ob];B[ja];W[la];B[db];W[cc];B[fe];W[cn];B[gr];W[is];B[fq];W[io];B[ji];W[eb];B[fb];W[eg];B[dj];W[dk];B[ej];W[cj];B[dh];W[ij];B[hm];W[gj];B[eh];W[fl];B[fg];W[er];B[dm];W[fn];B[dn];W[gn];B[jj];W[jk];B[kk];W[ii];B[ik];W[jl];B[kl];W[il];B[jh];W[co];B[do];W[ih];B[hn];W[hl];B[bl];W[dg];B[gh];W[ch];B[ig];W[ec];B[cr];W[fd];B[gd];W[ed];B[gc];W[bk];B[cm];W[gs];B[gp];W[li];B[kg];W[in];B[lj];W[lg];B[gm];W[jf];B[jg];W[im];B[fm];W[kf];B[lf];W[mf];B[le];W[gf];B[hf];W[ff];B[gg];W[lk];B[kj];W[km];B[lm];W[ll];B[jm];W[ge];B[he];W[ef];B[ea];W[cb];B[fr];W[fs];B[dr];W[qa];B[ra];W[pa];B[rb];W[da];B[gi];W[fj];B[fi];W[fa];B[ga];W[gl];B[ek];W[em];B[ho];W[el];B[en];W[jo];B[kn];W[ci];B[lh];W[mh];B[mg];W[di];B[ei];W[lg];B[qn];W[rn];B[re];W[sl];B[mg];W[bm];B[am];W[lg];B[eq];W[es];B[mg];W[ha];B[gb];W[lg];B[ds];W[hs];B[mg];W[sj];B[si];W[lg];B[sr];W[sq];B[mg];W[hd];B[hb];W[lg];B[ro];W[so];B[mg];W[ss];B[qs];W[lg];B[sn];W[rp];B[mg];W[cl];B[bn];W[lg];B[ml];W[mk];B[mg];W[pj];B[sf];W[lg];B[nn];W[nl];B[mg];W[ib];B[ia];W[lg];B[nc];W[nb];B[mg];W[jd];B[kd];W[lg];B[ma];W[na];B[mg];W[qc];B[rc];W[lg];B[js];W[ks];B[mg];W[hc];B[id];W[lg];B[fk];W[hj];B[mg];W[hh];B[hg];W[lg];B[gk];W[hk];B[mg];W[ak];B[lg];W[al];B[bm];W[nf];B[od];W[ki];B[ms];W[kp];B[ip];W[jp];B[lr];W[oj];B[mr];W[ea];B[sr])"

    /// Whether this process was launched to be photographed.
    ///
    /// Hard `false` outside DEBUG. Every call site guards on this, so the whole
    /// feature constant-folds away in a release build even where the call is
    /// not itself inside an `#if DEBUG`.
    public static var isActive: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
        return false
        #endif
    }

    // MARK: - Readiness marker

    /// The file `capture_screenshots.sh` polls for. Its EXISTENCE is the whole
    /// protocol; the contents are never read.
    public static let readinessMarkerName = "screenshot-ready"

    /// Where the marker is written, and therefore what the script has to look
    /// for under `simctl get_app_container <udid> <bundle> data`:
    /// `Documents/screenshot-ready` everywhere except tvOS, which uses
    /// `Library/Caches/screenshot-ready`.
    ///
    /// tvOS gets its own answer because `Documents` is NOT writable on a real
    /// Apple TV (it is in the Simulator, which is exactly the trap: the code
    /// would work in every capture run and fail the one time somebody pointed
    /// it at hardware). `Library/Caches` is writable on both.
    public static var readinessMarkerURL: URL? {
        #if os(tvOS)
        let directory = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let directory = FileManager.SearchPathDirectory.documentDirectory
        #endif
        guard let base = FileManager.default.urls(for: directory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent(readinessMarkerName, isDirectory: false)
    }

    /// Announce "this screen is worth photographing now".
    ///
    /// Deliberately stateless — it checks the file rather than latching in a
    /// `static var` — so it is safe to call from an analysis observer that
    /// fires ten times a second without any Swift 6 shared-mutable-state
    /// machinery. No-op unless the launch argument is present.
    public static func touchReadinessMarker() {
        guard isActive, let url = readinessMarkerURL else { return }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else { return }
        manager.createFile(atPath: url.path, contents: Data())
    }

    /// Clear a marker left behind by a previous capture run.
    ///
    /// A persisted simulator keeps its container, so without this the script's
    /// first poll would succeed instantly and photograph the launch screen. The
    /// script removes the file too; this is the half that also protects a run
    /// started by hand.
    public static func resetReadinessMarker() {
        guard isActive, let url = readinessMarkerURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Seeding

    /// Find-or-create the screenshot record in `context` and park it on
    /// `displayIndex`.
    ///
    /// Built from this package's own initializers rather than
    /// `GameRecord.createGameRecord`, which lives in KataGoUICore and needs the
    /// C++ SGF parser: the watch app cannot link either. Nothing is lost by
    /// that — every platform with an engine re-derives board size, komi and
    /// rules from the SGF in `GobanState.loadGame` on every open, and the watch
    /// replays the SGF itself and reads none of the `Config`.
    ///
    /// Idempotent, and it refreshes `lastModificationDate` on an existing
    /// record: every platform's boot opens the most-recently-modified game, so
    /// a stale seed would lose that race to whatever else the simulator has
    /// accumulated.
    @MainActor
    @discardableResult
    public static func seed(into context: ModelContext) -> GameRecord? {
        guard isActive else { return nil }

        let target: UUID? = uuid
        var descriptor = FetchDescriptor<GameRecord>(predicate: #Predicate { $0.uuid == target })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.currentIndex = displayIndex
            existing.lastModificationDate = Date.now
            try? context.save()
            return existing
        }

        let config = Config(boardWidth: 19,
                            boardHeight: 19,
                            rule: Config.rules.firstIndex(of: ruleToken) ?? Config.defaultRule,
                            komi: 0)
        let record = GameRecord(sgf: sgf,
                                currentIndex: displayIndex,
                                config: config,
                                name: recordName,
                                lastModificationDate: Date.now,
                                width: 19,
                                height: 19)
        config.gameRecord = record
        record.uuid = uuid
        context.insert(record)
        try? context.save()
        return record
    }

    // MARK: - The Apple TV play variant

    /// `currentIndex` for the Apple TV variant: one move short of the seed, so
    /// Black — the human — is on the ear-reddening move when the shot is taken.
    public static let playVariantDisplayIndex = 127 - 1

    /// The Apple TV Play-screen variant of the record.
    ///
    /// `TVPlayability` routes the plain seed to the read-only REVIEW screen: it
    /// carries `RE[B+2]`, so `SelfPlayGame.recordedGameIsFinished` is true, and
    /// both sides are human. The README wants the Play screen, so this strips
    /// the result tag and truncates the moves; the caller hands White to the AI.
    public static var playVariantSgf: String {
        truncated(sgf: sgf, afterMoves: playVariantDisplayIndex, removingResult: true)
    }

    /// Splits a FLAT main-line SGF on its node separators.
    ///
    /// Correct for THIS record and nothing else: `sgf` above carries no comment
    /// (`C[...]`), label or any other free-text property, so no `;` can hide
    /// inside a property value and no variation `(` can open mid-record. The
    /// real parser is in the C++ bridge, which is the one thing this package
    /// may not reach. Non-public for that reason.
    static func truncated(sgf: String, afterMoves count: Int, removingResult: Bool) -> String {
        guard sgf.hasPrefix("("), sgf.hasSuffix(")") else { return sgf }
        let body = sgf.dropFirst().dropLast()
        // `omittingEmptySubsequences: false` keeps the empty leading element
        // before the first `;`, so re-joining restores the leading separator.
        var nodes = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard nodes.count > 1 else { return sgf }
        if removingResult,
           let range = nodes[1].range(of: "RE\\[[^\\]]*\\]", options: .regularExpression) {
            nodes[1].removeSubrange(range)
        }
        let keep = min(nodes.count, 2 + max(0, count))
        return "(" + nodes[0..<keep].joined(separator: ";") + ")"
    }
}
