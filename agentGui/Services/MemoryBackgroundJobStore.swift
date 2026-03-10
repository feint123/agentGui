import Foundation

struct MemoryBackgroundJobStore {
    private let jobsFileURL: URL
    private let latestSweepFileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.jobsFileURL = baseDirectory.appending(path: "memory-background-jobs.json")
        self.latestSweepFileURL = baseDirectory.appending(path: "memory-latest-sweep-report.json")
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func enqueue(_ job: MemoryBackgroundJob) throws {
        var jobs = try allJobs()
        jobs.append(job)
        try save(jobs)
    }

    func allJobs() throws -> [MemoryBackgroundJob] {
        guard fileManager.fileExists(atPath: jobsFileURL.path) else { return [] }
        let data = try Data(contentsOf: jobsFileURL)
        return try decoder.decode([MemoryBackgroundJob].self, from: data)
    }

    func nextQueuedJob() throws -> MemoryBackgroundJob? {
        try allJobs().first(where: { $0.status == .queued })
    }

    func hasPendingJobs(types: Set<MemoryBackgroundJob.JobType>? = nil) throws -> Bool {
        try allJobs().contains { job in
            let matchesType = types.map { $0.contains(job.type) } ?? true
            return matchesType && (job.status == .queued || job.status == .running)
        }
    }

    func markRunning(jobID: String, at date: Date = Date()) throws {
        try mutate(jobID: jobID) { job in
            job.status = .running
            job.lastRunAt = date
            job.attemptCount += 1
            job.failureSummary = nil
        }
    }

    func markCompleted(jobID: String, at date: Date = Date()) throws {
        try mutate(jobID: jobID) { job in
            job.status = .completed
            job.completedAt = date
            job.lastRunAt = date
            job.failureSummary = nil
        }
    }

    func markFailed(jobID: String, summary: String, at date: Date = Date()) throws {
        try mutate(jobID: jobID) { job in
            job.status = .failed
            job.failureSummary = summary
            job.lastRunAt = date
        }
    }

    func saveLatestSweepReport(_ report: MemorySweepReport) throws {
        try ensureBaseDirectoryExists()
        let data = try encoder.encode(report)
        try data.write(to: latestSweepFileURL, options: .atomic)
    }

    func latestSweepReport() -> MemorySweepReport? {
        guard fileManager.fileExists(atPath: latestSweepFileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: latestSweepFileURL) else { return nil }
        return try? decoder.decode(MemorySweepReport.self, from: data)
    }

    private func mutate(jobID: String, mutate: (inout MemoryBackgroundJob) -> Void) throws {
        var jobs = try allJobs()
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            throw MemoryStoreError.recordNotFound(jobID)
        }
        mutate(&jobs[index])
        try save(jobs)
    }

    private func save(_ jobs: [MemoryBackgroundJob]) throws {
        try ensureBaseDirectoryExists()
        let data = try encoder.encode(jobs)
        try data.write(to: jobsFileURL, options: .atomic)
    }

    private func ensureBaseDirectoryExists() throws {
        let baseDirectory = jobsFileURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: baseDirectory.path) else { return }
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }
}