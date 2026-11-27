import Testing
@testable import RVTerm

@Test func termView_numbersAndDeepLinks() {
    #expect(TermView.allCases.map(\.number) == [1, 2, 3])
    #expect(TermView.allCases.map(\.deepLinkName) == ["glance", "stream", "needs-you"])
    for view in TermView.allCases {
        #expect(TermView(number: view.number) == view)
        #expect(TermView(deepLinkName: view.deepLinkName) == view)
    }
    #expect(TermView(deepLinkName: "Needs_You") == .needsYou)
    #expect(TermView(deepLinkName: "needsyou") == .needsYou)
    #expect(TermView(deepLinkName: "watched") == .stream)
    #expect(TermView(deepLinkName: "week") == nil)
    #expect(TermView(deepLinkName: "posture") == nil)
    #expect(TermView(deepLinkName: "now") == nil)
    #expect(TermView(number: 0) == nil)
    #expect(TermView(number: 4) == nil)
}

@Test func navigation_startsOnGlance() {
    let nav = TermNavigation()
    #expect(nav.current == .glance)
    #expect(nav.history.isEmpty)
}

@Test func navigation_digitsOpenViews() {
    var nav = TermNavigation()
    let handled1 = nav.handle(.digit(3))
    #expect(handled1)
    #expect(nav.current == .needsYou)
    let handled2 = nav.handle(.digit(9))
    #expect(handled2 == false)
    #expect(nav.current == .needsYou)
}

@Test func navigation_escapeWalksBackTheWayYouCame() {
    var nav = TermNavigation()
    nav.handle(.digit(3))
    nav.handle(.digit(2))
    #expect(nav.current == .stream)
    let handled3 = nav.handle(.escape)
    #expect(handled3)
    #expect(nav.current == .needsYou)
    let handled4 = nav.handle(.escape)
    #expect(handled4)
    #expect(nav.current == .glance)
    let handled5 = nav.handle(.escape)
    #expect(handled5 == false)
    #expect(nav.current == .glance)
}

@Test func navigation_escapeWithNoHistoryGoesHome() {
    var nav = TermNavigation(start: .needsYou)
    let handled6 = nav.handle(.escape)
    #expect(handled6)
    #expect(nav.current == .glance)
}

@Test func navigation_reopeningTheSameViewAddsNoHistory() {
    var nav = TermNavigation()
    nav.handle(.digit(3))
    nav.handle(.digit(3))
    #expect(nav.history == [.glance])
}

@Test func navigation_spaceSwapsGlanceAndStream() {
    var nav = TermNavigation()
    nav.handle(.space)
    #expect(nav.current == .stream)
    nav.handle(.space)
    #expect(nav.current == .glance)
    nav.handle(.digit(3))
    nav.handle(.space)
    #expect(nav.current == .stream)
}

@Test func navigation_tabWraps() {
    var nav = TermNavigation(start: .needsYou)
    nav.handle(.tab)
    #expect(nav.current == .glance)
    nav.handle(.backTab)
    #expect(nav.current == .needsYou)
}

@Test func navigation_historyIsBounded() {
    var nav = TermNavigation()
    for i in 0..<100 {
        nav.handle(.digit(i % 2 == 0 ? 2 : 3))
    }
    #expect(nav.history.count == TermNavigation.historyLimit)
}
