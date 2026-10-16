import XCTest
import Combine
import UserNotifications
import MakoshCore
import MakoshTelegram
@testable import MakoshMail
@testable import MakoshApp

@MainActor final class MailCenterProbe: ApplicationSystemNotificationCenter {
    var authorization:UNAuthorizationStatus = .authorized
    var requests = 0
    var cards:[UNNotificationRequest] = []
    var observedPending: [UNNotificationRequest] = []
    var onRemove: (([String]) -> Void)?
    var removed = Set<String>()
    var holdStatus = false, holdAdd = false
    var statuses:[@Sendable (UNAuthorizationStatus)->Void] = []
    var consent:(@Sendable (Bool,(any Error)?)->Void)?
    var adds:[@Sendable ((any Error)?)->Void] = []
    var onRequest:(()->Void)?, onAdd:(()->Void)?
    func getAuthorizationStatus(completionHandler:@escaping @Sendable (UNAuthorizationStatus)->Void) { if holdStatus { statuses.append(completionHandler) } else { completionHandler(authorization) } }
    func requestAuthorization(options:UNAuthorizationOptions,completionHandler:@escaping @Sendable (Bool,(any Error)?)->Void) { requests += 1;consent=completionHandler;onRequest?() }
    func add(_ request:UNNotificationRequest,withCompletionHandler completionHandler:(@Sendable ((any Error)?)->Void)?) { cards.append(request);onAdd?();if let completionHandler { if holdAdd { adds.append(completionHandler) } else { completionHandler(nil) } } }
    func getDeliveredNotifications(completionHandler:@escaping @Sendable ([UNNotification])->Void) { completionHandler([]) }
    func getPendingNotificationRequests(completionHandler:@escaping @Sendable ([UNNotificationRequest])->Void) { completionHandler(observedPending) }
    func removePendingNotificationRequests(withIdentifiers ids:[String]) { removed.formUnion(ids); onRemove?(ids) }
    func removeDeliveredNotifications(withIdentifiers ids:[String]) { removed.formUnion(ids); onRemove?(ids) }
    func resolveConsent(_ allowed:Bool,error:Bool=false) { authorization = error ? .notDetermined : allowed ? .authorized : .denied;let callback=consent;consent=nil;callback?(allowed,error ? NSError(domain:"synthetic",code:1):nil) }
    func resolveStatuses() { let callbacks=statuses;statuses=[];callbacks.forEach { $0(authorization) } }
}

@MainActor final class MailNotificationPresentationTests: XCTestCase {
    private func setup(_ accountID:String="a") -> (MailNotificationController,MailSnapshot,MailLetter) {
        let controller=MailNotificationController()
        let letter=MailLetter(key:.init(accountID:accountID,folder:"INBOX",uidValidity:7,uid:11),subject:"Private subject",senderName:"Private sender",sender:"peer@example.invalid",recipient:"qa@example.invalid",date:Date())
        var snapshot=MailSnapshot()
        snapshot.accounts=[.init(id:accountID,displayName:"QA",email:"qa@example.invalid",imapHost:"imap.example.invalid",imapUsername:"qa",smtpHost:"smtp.example.invalid",smtpUsername:"qa")]
        snapshot.folders=[.init(accountID:accountID,path:"INBOX",kind:.inbox,uidValidity:7)]
        snapshot.letters=[letter];snapshot.notifications = .init()
        controller.update(snapshot:snapshot,connected:[accountID]);return(controller,snapshot,letter)
    }
    func testRestoredCardsAreKeptUntilHydrationThenRemovedWhenPrivacyChanges() async {
        let (_, base, letter) = setup()
        let controller = MailNotificationController(), center = MailCenterProbe()
        let system = MailSystemNotifications(controller: controller, center: center)
        let router = ApplicationSystemNotificationRouter(registerSystemDelegate: false)
        let identifier = "makosh.mail." + letter.id
        center.observedPending = [UNNotificationRequest(identifier: identifier, content: UNMutableNotificationContent(), trigger: nil), UNNotificationRequest(identifier: "makosh.telegram.keep", content: UNMutableNotificationContent(), trigger: nil)]
        system.attach(router)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(center.removed.contains(identifier), "Cold cards must wait for trusted hydration")
        var snapshot = base
        snapshot.notifications?.routes = [letter.id: .init(event: .init(letter: letter), rule: .init())]
        controller.update(snapshot: snapshot, connected: [])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(center.removed.contains(identifier))
        let cleared = expectation(description: "Restored card cleared after privacy OFF")
        center.onRemove = { ids in if ids.contains(identifier) { cleared.fulfill() } }
        snapshot.notifications?.preferences.global.enabled = false
        controller.update(snapshot: snapshot, connected: [])
        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertFalse(center.removed.contains("makosh.telegram.keep"))
    }
    func testFirstIncomingRequestsOnceAndSubmitsAfterGrant() async throws {
        let (controller,_,letter)=setup(),center=MailCenterProbe();center.authorization = .notDetermined
        let system=MailSystemNotifications(controller:controller,center:center)
        let router=ApplicationSystemNotificationRouter(registerSystemDelegate:false);system.attach(router)
        let consent=expectation(description:"one initial request"), card=expectation(description:"card after grant")
        center.onRequest={consent.fulfill()};center.onAdd={card.fulfill()}
        controller.receive(.init(letter:letter))
        await fulfillment(of:[consent],timeout:2);XCTAssertTrue(center.cards.isEmpty)
        center.resolveConsent(true);await fulfillment(of:[card],timeout:2)
        XCTAssertEqual(center.requests,1);XCTAssertEqual(center.cards.first?.content.body,"Private subject")
        XCTAssertEqual(Set(center.cards.first?.content.userInfo.keys.compactMap { $0 as? String } ?? []),["makosh.mail.token"])
    }
    func testDeniedPermissionDoesNotRequestOrSubmit() async {
        let (controller,_,letter)=setup(),center=MailCenterProbe();center.authorization = .denied
        let system=MailSystemNotifications(controller:controller,center:center),router=ApplicationSystemNotificationRouter(registerSystemDelegate:false)
        system.attach(router);controller.receive(.init(letter:letter))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(center.requests,0);XCTAssertTrue(center.cards.isEmpty)
    }
    func testPermissionErrorDoesNotAutomaticallyPromptAgainButManualRetryWorks() async {
        let (controller,_,letter)=setup(),center=MailCenterProbe();center.authorization = .notDetermined
        let system=MailSystemNotifications(controller:controller,center:center),router=ApplicationSystemNotificationRouter(registerSystemDelegate:false)
        system.attach(router)
        let requested=expectation(description:"request");center.onRequest={requested.fulfill()}
        controller.receive(.init(letter:letter));await fulfillment(of:[requested],timeout:2);center.onRequest=nil
        center.resolveConsent(false,error:true)
        for _ in 0..<20 { await Task.yield() }
        var next=letter;next.key = .init(accountID:"a",folder:"INBOX",uidValidity:7,uid:12)
        var snapshot=setup().1;snapshot.letters.append(next);controller.update(snapshot:snapshot,connected:["a"])
        controller.receive(.init(letter:next));for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(center.requests,1);system.requestAuthorization();XCTAssertEqual(center.requests,2)
    }
    func testMutedSenderWhileAuthorizationIsPendingCannotLeakOldPreview() async {
        let (controller,base,letter)=setup(),center=MailCenterProbe();center.authorization = .notDetermined
        let system=MailSystemNotifications(controller:controller,center:center),router=ApplicationSystemNotificationRouter(registerSystemDelegate:false)
        system.attach(router);let requested=expectation(description:"request");center.onRequest={requested.fulfill()}
        controller.receive(.init(letter:letter));await fulfillment(of:[requested],timeout:2)
        var changed=base;changed.notifications?.preferences.overrides[MailNotificationScope.sender(accountID:"a",address:letter.sender).id] = .init(enabled:false)
        controller.update(snapshot:changed,connected:["a"]);center.resolveConsent(true)
        for _ in 0..<20 { await Task.yield() };XCTAssertTrue(center.cards.isEmpty)
    }
    func testReadChangeAndDisconnectRemovePendingOrSubmittedCards() async {
        let (controller,base,letter)=setup(),center=MailCenterProbe();center.holdAdd=true
        let system=MailSystemNotifications(controller:controller,center:center),router=ApplicationSystemNotificationRouter(registerSystemDelegate:false)
        system.attach(router);let added=expectation(description:"add");center.onAdd={added.fulfill()}
        controller.receive(.init(letter:letter));await fulfillment(of:[added],timeout:2)
        guard let id=center.cards.first?.identifier else { XCTFail("No incoming card submitted"); return }
        var changed=base;changed.letters[0].seen=true
        controller.update(snapshot:changed,connected:[]);center.adds.forEach{$0(nil)}
        for _ in 0..<20 { await Task.yield() };XCTAssertTrue(center.removed.contains(id))
    }
    func testPreviewAndSoundRestrictionsProduceGenericSilentCard() throws {
        let (controller,base,letter)=setup();var changed=base
        changed.notifications?.preferences.global = .init(previews:false,sound:false)
        controller.update(snapshot:changed,connected:["a"]);controller.receive(.init(letter:letter))
        let content=mailSystemNotificationContent(try XCTUnwrap(controller.delivery))
        XCTAssertFalse(content.title.contains("Private"));XCTAssertFalse(content.body.contains("Private"));XCTAssertNil(content.sound)
    }
    func testForegroundSuppressionRequiresOwningKeyVisibleNonminimizedWindow() {
        let (controller,base,letter)=setup();var changed=base;changed.notifications?.preferences.showWhileActive=false
        controller.update(snapshot:changed,connected:["a"])
        controller.setPresentationEnvironment(active:false,locked:false);controller.receive(.init(letter:letter));XCTAssertNotNil(controller.delivery)
        controller.setPresentationEnvironment(active:true,locked:false);XCTAssertFalse(controller.canPresent(identifier:letter.id))
        XCTAssertFalse(applicationNotificationWindowIsActive(.init(applicationActive:true,hasWindow:true,key:true,visible:true,miniaturized:true)))
    }
    func testScreenLockAndNamespaceClearingPreserveTelegramCards() {
        let (controller,_,letter)=setup();controller.receive(.init(letter:letter))
        controller.setPresentationEnvironment(active:false,locked:true);XCTAssertFalse(controller.canPresent(identifier:letter.id))
        XCTAssertEqual(mailNotificationIDsToClear(["makosh.telegram.keep","makosh.mail.old","makosh.mail.keep"],keeping:["makosh.mail.keep"]),["makosh.mail.old"])
    }
    func testOpaqueActionRoutesOnceAndRejectsUnknownOrStaleAccount() {
        let (controller,base,letter)=setup(),registry=MailNotificationRegistry()
        var actions:[MailNotificationAction]=[]
        _=registry.register(controller) { action,event in XCTAssertEqual(event.key.uid,11);actions.append(action) }
        controller.receive(.init(letter:letter));XCTAssertTrue(registry.admitDelivery(controller:controller,identifier:letter.id))
        registry.activate(identifier:"forged",action:.trash);registry.activate(identifier:letter.id,action:.archive);registry.activate(identifier:letter.id,action:.trash)
        XCTAssertEqual(actions,[.archive])
        controller.update(snapshot:base,connected:[]);XCTAssertFalse(registry.canPresent(identifier:letter.id))
    }
    func testMailWaitsForSharedTelegramConsentWithoutAnotherPrompt() async {
        let (controller,_,letter)=setup(),center=MailCenterProbe();center.authorization = .notDetermined
        let router=ApplicationSystemNotificationRouter(registerSystemDelegate:false)
        let suite="org.makosh.mail-notification-test."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let telegram=TelegramSystemNotifications(controller:TelegramNotificationController(defaults:defaults),center:center)
        let mail=MailSystemNotifications(controller:controller,center:center)
        telegram.attach(router);mail.attach(router);telegram.requestAuthorization()
        controller.receive(.init(letter:letter))
        for _ in 0..<20 { await Task.yield() };XCTAssertEqual(center.requests,1)
        let card=expectation(description:"mail after shared grant");center.onAdd={card.fulfill()}
        center.resolveConsent(true);await fulfillment(of:[card],timeout:2)
        XCTAssertEqual(center.requests,1)
    }
    func testTwoWindowsCannotOwnTheSameOpaqueRoute() {
        let (a,_,letter)=setup(),(b,base,_)=setup(),registry=MailNotificationRegistry()
        var first=0,second=0
        _=registry.register(a) { _,_ in first += 1 };_=registry.register(b) { _,_ in second += 1 }
        a.receive(.init(letter:letter));b.receive(.init(letter:letter))
        XCTAssertTrue(registry.admitDelivery(controller:a,identifier:letter.id))
        XCTAssertFalse(registry.admitDelivery(controller:b,identifier:letter.id))
        registry.activate(identifier:letter.id,action:.open)
        XCTAssertEqual(first,1);XCTAssertEqual(second,0)
        a.update(snapshot:base,connected:[])
        XCTAssertTrue(registry.admitDelivery(controller:b,identifier:letter.id))
    }
    func testSharedConsentCompletesAfterRequestingWindowCloses() async {
        let (controller,_,letter)=setup(),center=MailCenterProbe();center.authorization = .notDetermined
        let router=ApplicationSystemNotificationRouter(registerSystemDelegate:false)
        var system:MailSystemNotifications?=MailSystemNotifications(controller:controller,center:center)
        system?.attach(router);system?.requestAuthorization();system=nil
        center.resolveConsent(true)
        for _ in 0..<20 { await Task.yield() }
        let next=MailSystemNotifications(controller:controller,center:center);next.attach(router)
        let card=expectation(description:"card after closed owner grant");center.onAdd={card.fulfill()}
        controller.receive(.init(letter:letter));await fulfillment(of:[card],timeout:2)
        XCTAssertFalse(router.authorizationRequesting)
    }
    func testRegisteredCardActionSurvivesOwningWindowForegroundTransition() {
        let (controller,base,letter)=setup(),registry=MailNotificationRegistry()
        var snapshot=base;snapshot.notifications?.preferences.showWhileActive=false
        controller.update(snapshot:snapshot,connected:["a"])
        var actions=0;_=registry.register(controller) { _,_ in actions += 1 }
        controller.receive(.init(letter:letter));XCTAssertTrue(registry.admitDelivery(controller:controller,identifier:letter.id))
        controller.setPresentationEnvironment(active:true,locked:false)
        registry.activate(identifier:letter.id,action:.archive)
        XCTAssertEqual(actions,1)
    }
}
