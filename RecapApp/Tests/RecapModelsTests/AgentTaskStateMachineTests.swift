import XCTest
@testable import RecapModels

final class AgentTaskStateMachineTests: XCTestCase {

    func testLegalTransitions() {
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .queued, to: .running))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .queued, to: .cancelled))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .running, to: .suspended))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .running, to: .awaitingApproval))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .running, to: .succeeded))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .running, to: .partial))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .running, to: .failed))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .running, to: .cancelled))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .suspended, to: .running))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .suspended, to: .cancelled))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .awaitingApproval, to: .running))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .awaitingApproval, to: .cancelled))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .partial, to: .running))
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .partial, to: .cancelled))
    }

    func testTerminalCannotLeave() {
        let all: [AgentTaskState] = [
            .queued, .running, .suspended, .awaitingApproval,
            .succeeded, .partial, .failed, .cancelled,
        ]
        for terminal: AgentTaskState in [.succeeded, .failed, .cancelled] {
            for next in all where next != terminal {
                XCTAssertFalse(
                    AgentTaskTransition.canTransition(from: terminal, to: next),
                    "\(terminal) → \(next) should be rejected"
                )
            }
        }
    }

    func testSuspendedToRunningAllowed() {
        XCTAssertTrue(AgentTaskTransition.canTransition(from: .suspended, to: .running))
    }

    func testModelTransitionUpdatesState() {
        let task = AgentTask(objective: "调研并拟定方案：测一下")
        XCTAssertEqual(task.state, .queued)
        XCTAssertTrue(task.transition(to: .running))
        XCTAssertEqual(task.state, .running)
        XCTAssertFalse(task.transition(to: .queued))
        XCTAssertEqual(task.state, .running)
        XCTAssertTrue(task.transition(to: .succeeded))
        XCTAssertTrue(task.isTerminal)
        XCTAssertFalse(task.transition(to: .running))
    }
}
