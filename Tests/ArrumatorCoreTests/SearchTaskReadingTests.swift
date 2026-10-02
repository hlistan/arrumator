@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// How a search task's request is read (docs/how-it-works.md#search-tasks): with the task's effort, and by its own model
/// profile, else by the one Settings uses when it is read. Another effort or profile reads it again and the same changes
/// nothing; a profile the settings do not list is refused, and a task whose profile is gone fails saying so and waits
/// for another. The trace of each reading is stamped with the models of the profile that read it.
@Suite struct SearchTaskReadingTests {
    private let suite = SearchTaskTests()

    /// The models the trace of the task's last reading is stamped with: chat, vision, embedding.
    private func tracedModels(_ h: Harness, _ task: SearchTask) async throws -> [String?] {
        let id = try #require(task.lastTrace, "the task was read")
        let trace = try #require(try await h.services.traces.trace(id: id))
        return [trace.0.modelChat, trace.0.modelVision, trace.0.modelEmbed]
    }

    @Test func eachTaskIsReadWithItsEffortAndByItsProfileElseByTheOneSettingsUses() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let interpreter = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025])
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let settings = await w.h.env.settings.current
        let (standard, smart) = (try settings.modelProfile(), try settings.modelProfile("smart"))
        #expect(standard != smart, "the profiles these expectations tell apart")
        let defaults = try AppSettings.bundledDefaults().taskEffort
        let plain = try await tasks.create(prompt: SearchTaskTests.prompt)
        #expect(plain.effort == defaults && plain.profile == nil,
                "a new task is read with the effort Settings gives new tasks, and follows the profile Settings uses")
        try await w.h.env.settings.update { $0.taskEffort = .high }
        let careful = try await tasks.create(prompt: SearchTaskTests.prompt)
        #expect(careful.effort == .high, "whichever effort that is")
        let chosen = try await tasks.create(prompt: SearchTaskTests.prompt, effort: .low, profile: " smart\n")
        #expect(chosen.effort == .low && chosen.profile == "smart", "or with the effort and profile it is asked with, on one line")
        await queue.drain()
        let readings = await interpreter.calls.readings
        #expect(readings.map(\.effort) == [defaults, .high, .low], "each prompt is read with its task's effort")
        #expect(readings.map(\.profile) == [standard, standard, smart], "by its own profile when it has one, else by the one Settings uses")
        let read = try await suite.task(tasks, chosen.id)
        #expect(read.model == smart.chatModel && read.profile == "smart", "the task records the model that read it, and keeps its profile")
        #expect(try await tracedModels(w.h, read) == [smart.chatModel, smart.visionModel, smart.embedModel],
                "its trace is stamped with the models of the profile that read it, not with Settings'")
        #expect(try await tracedModels(w.h, try await suite.task(tasks, plain.id)) == [standard.chatModel, standard.visionModel, standard.embedModel],
                "and a task that follows Settings with those of Settings' profile")
        let asked = try await suite.events(w.h, [.taskCreated]).map(\.summary)
        #expect(asked.last == "Asked for “\(SearchTaskTests.prompt)”, read with low effort by Smart"
                    && asked.first?.hasSuffix("read with \(defaults.rawValue) effort by Settings' profile") == true,
                "History says how each task is to be read, its profile by name: \(asked)")
    }

    @Test func aTaskWithoutAProfileFollowsAChangeOfTheOneSettingsUses() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let interpreter = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025])
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let id = try await tasks.create(prompt: SearchTaskTests.prompt).id
        try await w.h.env.settings.update { $0.profile = "fast" }
        await queue.drain()
        try await w.h.env.settings.update { $0.profile = "smart" }
        _ = try await tasks.retry(id)
        await queue.drain()
        let settings = await w.h.env.settings.current
        let (fast, smart) = (try settings.modelProfile("fast"), try settings.modelProfile("smart"))
        #expect(await interpreter.calls.readings.map(\.profile) == [fast, smart],
                "a task that names no profile is read by the one Settings uses when it is read, not when it was asked")
        let read = try await suite.task(tasks, id)
        #expect(read.profile == nil && read.model == smart.chatModel, "it still follows Settings, and records the model that read it last")
    }

    @Test func anotherEffortOrProfileReadsTheTaskAgainAndTheSameChangesNothing() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let interpreter = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025])
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let settings = await w.h.env.settings.current
        let (standard, smart) = (try settings.modelProfile(), try settings.modelProfile("smart"))
        let id = try await tasks.create(prompt: SearchTaskTests.prompt, effort: .medium).id
        await queue.drain()
        let found = try await suite.task(tasks, id).documents

        var changed = try await tasks.update(id, SearchTaskChange(effort: .medium, profile: ""))
        let edited = try await suite.events(w.h, [.taskEdited])
        #expect(changed.state == .ready && edited.isEmpty, "the effort it has, and following Settings as it does, change nothing")
        changed = try await tasks.update(id, SearchTaskChange(effort: .high))
        #expect(changed.state == .queued && changed.effort == .high, "another effort sends the task back into the queue")
        await queue.drain()
        changed = try await tasks.update(id, SearchTaskChange(profile: "smart"))
        #expect(changed.state == .queued && changed.profile == "smart", "and so does another profile")
        await queue.drain()
        changed = try await tasks.update(id, SearchTaskChange(profile: "smart"))
        #expect(changed.state == .ready && changed.profile == "smart", "the profile it has already changes nothing")
        changed = try await tasks.update(id, SearchTaskChange(profile: ""))
        #expect(changed.profile == nil && changed.state == .queued, "an empty profile gives the task back to the one Settings uses")
        await queue.drain()
        #expect(await interpreter.calls.readings.dropFirst() == [StubInterpreter.Reading(effort: .high, profile: standard),
                                                                  StubInterpreter.Reading(effort: .high, profile: smart),
                                                                  StubInterpreter.Reading(effort: .high, profile: standard)],
                "each is read again as it was changed, and only then")
        #expect(try await suite.task(tasks, id).documents == found, "and finds its documents again")
        let edits = try await suite.events(w.h, [.taskEdited]).map(\.summary)
        #expect(edits == ["Changed the effort of “Utility invoices 2025”, read with high effort by Settings' profile",
                          "Changed the profile of “Utility invoices 2025”, read with high effort by Smart",
                          "Changed the profile of “Utility invoices 2025”, read with high effort by Settings' profile"],
                "each change is in History with how the task is read now: \(edits)")
    }

    @Test func aProfileTheSettingsDoNotListIsRefusedAndNothingIsWritten() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let interpreter = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025])
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let id = try await tasks.create(prompt: SearchTaskTests.prompt).id
        await queue.drain()
        let before = try await suite.task(tasks, id)
        let recorded = try await suite.events(w.h, [.taskCreated, .taskEdited]).count
        await #expect(throws: ModelProfileError.unknown("bogus"), "a task is not asked for with a profile there is none of, which is named") {
            try await tasks.create(prompt: "phone bills", effort: .high, profile: "bogus")
        }
        await #expect(throws: ModelProfileError.unknown("bogus"), "nor given one") {
            try await tasks.update(id, SearchTaskChange(title: "Bills", effort: .high, profile: "bogus"))
        }
        #expect(try await tasks.store.tasks().map(\.id) == [id], "no task was added")
        #expect(try await suite.task(tasks, id) == before, "and the task is as it was: not renamed, not given the effort, not queued again")
        #expect(try await suite.events(w.h, [.taskCreated, .taskEdited]).count == recorded, "and nothing is in History")
        await queue.drain()
        #expect(await interpreter.calls.readings.count == 1, "nor read again")
    }

    @Test func aTaskWhoseProfileIsGoneFailsSayingSoAndIsReadOnceGivenAnother() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let interpreter = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025])
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let mine = ModelProfile(name: "Mine", position: 4, chatModel: "gemma4:12b", visionModel: "gemma4:12b", embedModel: "bge-m3")
        try await w.h.env.settings.update { $0.modelProfiles["mine"] = mine }
        let id = try await tasks.create(prompt: SearchTaskTests.prompt, profile: "mine").id
        try await w.h.env.settings.update { $0.modelProfiles["mine"] = nil }
        await queue.drain()
        let failed = try await suite.task(tasks, id)
        #expect(failed.state == .failed && failed.problem == ModelProfileError.unknown("mine").localizedDescription
                    && failed.problem?.contains("mine") == true,
                "a profile that is gone will not come back by waiting, so the task says which one it needs: \(failed.problem ?? "")")
        #expect(failed.profile == "mine" && failed.documents.isEmpty, "and keeps it until the user gives it another")
        #expect(await interpreter.calls.readings.isEmpty, "no other profile reads it in its place unasked")
        #expect(try await tracedModels(w.h, failed) == [nil, nil, nil], "its trace names no models, as none read it")
        #expect(try await suite.events(w.h, [.taskFailed]).map(\.summary) == ["Could not read “\(SearchTaskTests.prompt)”: \(failed.problem ?? "")"],
                "History says why")
        await queue.drain()
        #expect(try await suite.task(tasks, id).state == .failed, "it waits for the user rather than failing again and again")

        let given = try await tasks.update(id, SearchTaskChange(profile: "smart"))
        #expect(given.state == .queued && given.problem == nil, "given another profile, it goes back into the queue")
        await queue.drain()
        let smart = try await w.h.env.settings.current.modelProfile("smart")
        #expect(try await suite.task(tasks, id).state == .ready, "and is read")
        #expect(await interpreter.calls.readings.map(\.profile) == [smart], "by the profile it was given")
    }

    @Test func anEffortChangedWhileThePromptWasBeingReadReadsItAgainWithTheNewOne() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let holder = TaskHolder()
        let interpreter = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025]) { _ in
            if let tasks = await holder.tasks, let id = await holder.id, try await tasks.store.task(id: id)?.effort == .low {
                try await tasks.update(id, SearchTaskChange(effort: .high))
            }
        }
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let asked = try await tasks.create(prompt: SearchTaskTests.prompt, effort: .low)
        await holder.set(tasks, asked.id)
        await queue.drain()
        #expect(await interpreter.calls.readings.map(\.effort) == [.low, .high], "the reading at the old effort is dropped")
        #expect(try await suite.task(tasks, asked.id).state == .ready, "and the task is ready from the new one")
    }
}
