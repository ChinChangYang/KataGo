//
//  SgfOperations.swift
//  KataGoUICore
//
//  Session-layer access point for SGF parsing. Wraps the Bridge SgfHelper so the
//  Model layer no longer constructs the C++ bridge parser directly; SGF parsing
//  is created in exactly one place. Instance-based to preserve the
//  build-once/loop-many pattern of the navigation call sites.
//
import Foundation

public final class SgfOperations {
    private let helper: SgfHelper
    public init(sgf: String) { self.helper = SgfHelper(sgf: sgf) }
    public func getMove(at index: Int) -> Move? { helper.getMove(at: index) }
    public func getComment(at index: Int) -> String? { helper.getComment(at: index) }
    public var moveSize: Int? { helper.moveSize }
    public var xSize: Int { helper.xSize }
    public var ySize: Int { helper.ySize }
    public var rules: Rules { helper.rules }
}
