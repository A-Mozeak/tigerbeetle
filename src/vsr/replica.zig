const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const constants = @import("../constants.zig");

const StaticAllocator = @import("../static_allocator.zig");
const GridType = @import("../lsm/grid.zig").GridType;
const MessagePool = @import("../message_pool.zig").MessagePool;
const Message = @import("../message_pool.zig").MessagePool.Message;
const RingBuffer = @import("../ring_buffer.zig").RingBuffer;
const ClientTable = @import("superblock_client_table.zig").ClientTable;

const vsr = @import("../vsr.zig");
const Header = vsr.Header;
const Timeout = vsr.Timeout;
const Command = vsr.Command;
const Version = vsr.Version;
const VSRState = vsr.VSRState;

const log = std.log.scoped(.replica);
const tracer = @import("../tracer.zig");

pub const Status = enum {
    normal,
    view_change,
    // Recovery (for replica_count > 1):
    //
    // 1. Open the replica:
    //    a. At replica start: `status=recovering`.
    //    b. Recover the WAL. Mark questionable entries as faulty.
    //    c. If the WAL has no entries (besides the initial commit), skip to step 3 with view 0.
    // 2. Run VSR recovery protocol:
    //    a. Send a `recovery` message to every replica (except self).
    //    b. Wait for f+1 `recovery_response` messages from replicas in `normal` status.
    //       Each `recovery_response` includes the current view number.
    //       Each `recovery_response` must include a nonce matching the `recovery` message.
    //    c. Wait for a `recovery_response` from the primary of the highest known view.
    // 3. Transition to `status=normal` with the discovered view number:
    //    * Set `op` to the highest op in the primary's recovery response.
    //    * Repair faulty messages.
    //    * Commit through to the discovered `commit_max`.
    //    * Set `state_machine.prepare_timeout` to the current op's timestamp.
    //
    // TODO Document state transfer in this progression.
    recovering,
};

const Nonce = u128;

const Prepare = struct {
    /// The current prepare message (used to cross-check prepare_ok messages, and for resending).
    message: *Message,

    /// Unique prepare_ok messages for the same view, op number and checksum from ALL replicas.
    ok_from_all_replicas: QuorumCounter = quorum_counter_null,

    /// Whether a quorum of prepare_ok messages has been received for this prepare.
    ok_quorum_received: bool = false,
};

const QuorumMessages = [constants.replicas_max]?*Message;
const quorum_messages_null = [_]?*Message{null} ** constants.replicas_max;

const QuorumCounter = std.StaticBitSet(constants.replicas_max);
const quorum_counter_null = QuorumCounter.initEmpty();

// CRITICAL: The number of prepare headers to include in the body:
// We must provide enough headers to cover all uncommitted headers so that the new
// primary (if we are in a view change) can decide whether to discard uncommitted headers
// that cannot be repaired because they are gaps, and this must be relative to the
// cluster as a whole (not relative to the difference between our op and commit number)
// as otherwise we would break correctness.
const view_change_headers_count = constants.pipeline_max;

comptime {
    assert(view_change_headers_count > 0);
    assert(view_change_headers_count >= constants.pipeline_max);
    assert(view_change_headers_count <=
        @divFloor(constants.message_size_max - @sizeOf(Header), @sizeOf(Header)));
}

pub fn ReplicaType(
    comptime StateMachine: type,
    comptime MessageBus: type,
    comptime Storage: type,
    comptime Time: type,
) type {
    const Grid = GridType(Storage);
    const SuperBlock = vsr.SuperBlockType(Storage);

    return struct {
        const Self = @This();

        const Journal = vsr.JournalType(Self, Storage);
        const Clock = vsr.Clock(Time);

        /// We use this allocator during open/init and then disable it.
        /// An accidental dynamic allocation after open/init will cause an assertion failure.
        static_allocator: StaticAllocator,

        /// The number of the cluster to which this replica belongs:
        cluster: u32,

        /// The number of replicas in the cluster:
        replica_count: u8,

        /// The index of this replica's address in the configuration array held by the MessageBus:
        replica: u8,

        /// The minimum number of replicas required to form a replication quorum:
        quorum_replication: u8,

        /// The minimum number of replicas required to form a view change quorum:
        quorum_view_change: u8,

        time: Time,

        /// A distributed fault-tolerant clock for lower and upper bounds on the primary's wall clock:
        clock: Clock,

        /// The persistent log of hash-chained journal entries:
        journal: Journal,

        /// An abstraction to send messages from the replica to another replica or client.
        /// The message bus will also deliver messages to this replica by calling `on_message_from_bus()`.
        message_bus: MessageBus,

        /// For executing service up-calls after an operation has been committed:
        state_machine: StateMachine,

        // TODO Document.
        superblock: SuperBlock,
        superblock_context: SuperBlock.Context = undefined,
        grid: Grid,
        opened: bool,

        /// The current view, initially 0:
        view: u32,

        /// The latest view, in which the replica's status was normal.
        view_normal: u32,

        /// The current status, either normal, view_change, or recovering:
        status: Status = .recovering,

        /// The op number assigned to the most recently prepared operation.
        ///
        /// Invariants (not applicable during status=recovering):
        /// * `replica.op` exists in the Journal.
        /// * `replica.op ≥ replica.commit_min`.
        /// * `replica.op - replica.commit_min    ≤ journal_slot_count`
        /// * `replica.op - replica.op_checkpoint ≤ journal_slot_count`
        ///   It is safe to overwrite `op_checkpoint` itself.
        /// * `replica.op ≤ replica.op_checkpoint_trigger`:
        ///   Don't wrap the WAL until we are sure that the overwritten entry will not be required
        ///   for recovery.
        // TODO: When recovery protocol is removed, load the `op` from the WAL, and verify that it is ≥op_checkpoint.
        // Also verify that a corresponding header exists in the WAL.
        op: u64,

        /// The op of the highest checkpointed message.
        // TODO Refuse to store/ack any op>op_checkpoint+journal_slot_count.
        op_checkpoint: u64,

        /// The op number of the latest committed and executed operation (according to the replica):
        /// The replica may have to wait for repairs to complete before commit_min reaches commit_max.
        ///
        /// Invariants (not applicable during status=recovering):
        /// * `replica.commit_min` exists in the Journal OR `replica.commit_min == op_checkpoint`.
        /// * `replica.commit_min ≤ replica.op`
        /// * `replica.commit_min ≥ replica.op_checkpoint`.
        /// * never decreases while the replica is alive
        commit_min: u64,

        /// The op number of the latest committed operation (according to the cluster):
        /// This is the commit number in terms of the VRR paper.
        ///
        /// Invariants:
        /// * `replica.commit_max ≥ replica.commit_min`.
        /// * never decreases
        commit_max: u64,

        /// Guards against concurrent commits.
        ///
        /// Set while:
        /// * prefetching from storage, in preparation for a commit
        /// * reading a prepare from storage in order to commit
        /// * compacting storage
        /// * checkpointing
        committing: bool = false,

        /// Whether we are reading a prepare from storage in order to push to the pipeline.
        repairing_pipeline: bool = false,

        /// The primary's pipeline of inflight prepares waiting to commit in FIFO order.
        /// This allows us to pipeline without the complexity of out-of-order commits.
        ///
        /// After a view change, the old primary's pipeline is left untouched so that it is able to
        /// help the new primary repair, even in the face of local storage faults.
        pipeline: RingBuffer(Prepare, constants.pipeline_max, .array) = .{},

        /// In some cases, a replica may send a message to itself. We do not submit these messages
        /// to the message bus but rather queue them here for guaranteed immediate delivery, which
        /// we require and assert in our protocol implementation.
        loopback_queue: ?*Message = null,

        /// Unique start_view_change messages for the same view from OTHER replicas (excluding ourself).
        start_view_change_from_other_replicas: QuorumCounter = quorum_counter_null,

        /// Unique do_view_change messages for the same view from ALL replicas (including ourself).
        do_view_change_from_all_replicas: QuorumMessages = quorum_messages_null,

        /// Unique nack_prepare messages for the same view from OTHER replicas (excluding ourself).
        nack_prepare_from_other_replicas: QuorumCounter = quorum_counter_null,

        /// Unique recovery_response messages from OTHER replicas (excluding ourself).
        recovery_response_from_other_replicas: QuorumMessages = quorum_messages_null,

        /// Whether a replica has received a quorum of start_view_change messages for the view change:
        start_view_change_quorum: bool = false,

        /// Whether the primary has received a quorum of do_view_change messages for the view change:
        /// Determines whether the primary may effect repairs according to the CTRL protocol.
        do_view_change_quorum: bool = false,

        /// Whether the primary is expecting to receive a nack_prepare and for which op:
        nack_prepare_op: ?u64 = null,

        /// The number of ticks before a primary or backup broadcasts a ping to other replicas.
        /// TODO Explain why we need this (MessageBus handshaking, leapfrogging faulty replicas,
        /// deciding whether starting a view change would be detrimental under some network partitions).
        ping_timeout: Timeout,

        /// The number of ticks without enough prepare_ok's before the primary resends a prepare.
        prepare_timeout: Timeout,

        /// The number of ticks before the primary sends a commit heartbeat:
        /// The primary always sends a commit heartbeat irrespective of when it last sent a prepare.
        /// This improves liveness when prepare messages cannot be replicated fully due to partitions.
        commit_timeout: Timeout,

        /// The number of ticks without hearing from the primary before starting a view change.
        /// This transitions from .normal status to .view_change status.
        normal_status_timeout: Timeout,

        /// The number of ticks before a view change is timed out:
        /// This transitions from `view_change` status to `view_change` status but for a newer view.
        view_change_status_timeout: Timeout,

        /// The number of ticks before resending a `start_view_change` or `do_view_change` message:
        view_change_message_timeout: Timeout,

        /// The number of ticks before repairing missing/disconnected headers and/or dirty entries:
        repair_timeout: Timeout,

        /// The number of ticks before attempting to send another set of `recovery` messages.
        recovery_timeout: Timeout,

        /// The nonce of the `recovery` messages.
        recovery_nonce: Nonce,

        /// Used to provide deterministic entropy to `choose_any_other_replica()`.
        /// Incremented whenever `choose_any_other_replica()` is called.
        choose_any_other_replica_ticks: u64 = 0,

        /// Used to calculate exponential backoff with random jitter.
        /// Seeded with the replica's index number.
        prng: std.rand.DefaultPrng,

        /// Simulator hooks.
        on_change_state: ?fn (replica: *const Self) void = null,
        /// Called immediately after a compaction.
        on_compact: ?fn (replica: *const Self) void = null,
        /// Called immediately after a checkpoint.
        /// Note: The replica may checkpoint without calling this function:
        /// 1. Begin checkpoint.
        /// 2. Write 2/4 SuperBlock copies.
        /// 3. Crash.
        /// 4. Recover in the new checkpoint (but op_checkpoint wasn't called).
        on_checkpoint: ?fn (replica: *const Self) void = null,

        /// Called when `commit_prepare` finishes committing.
        commit_callback: ?fn (*Self) void = null,

        /// The prepare message being committed.
        commit_prepare: ?*Message = null,

        tracer_slot_commit: ?tracer.SpanStart = null,
        tracer_slot_checkpoint: ?tracer.SpanStart = null,

        const OpenOptions = struct {
            replica_count: u8,
            storage_size_limit: u64,
            storage: *Storage,
            message_pool: *MessagePool,
            time: Time,
            state_machine_options: StateMachine.Options,
            message_bus_options: MessageBus.Options,
        };

        /// Initializes and opens the provided replica using the options.
        pub fn open(self: *Self, parent_allocator: std.mem.Allocator, options: OpenOptions) !void {
            assert(options.storage_size_limit <= constants.storage_size_max);
            assert(options.storage_size_limit % constants.sector_size == 0);

            self.static_allocator = StaticAllocator.init(parent_allocator);
            const allocator = self.static_allocator.allocator();

            self.superblock = try SuperBlock.init(
                allocator,
                .{
                    .storage = options.storage,
                    .storage_size_limit = options.storage_size_limit,
                    .message_pool = options.message_pool,
                },
            );

            // Once initialzed, the replica is in charge of calling superblock.deinit()
            var initialized = false;
            errdefer if (!initialized) self.superblock.deinit(allocator);

            // Open the superblock:
            self.opened = false;
            self.superblock.open(superblock_open_callback, &self.superblock_context);
            while (!self.opened) self.superblock.storage.tick();
            assert(self.superblock.working.vsr_state.internally_consistent());

            if (self.superblock.working.replica >= options.replica_count) {
                log.err("{}: open: no address for replica (replica_count={})", .{
                    self.superblock.working.replica,
                    options.replica_count,
                });
                return error.NoAddress;
            }

            // Initialize the replica:
            try self.init(allocator, .{
                .cluster = self.superblock.working.cluster,
                .replica_index = self.superblock.working.replica,
                .replica_count = options.replica_count,
                .storage = options.storage,
                .time = options.time,
                .message_pool = options.message_pool,
                .state_machine_options = options.state_machine_options,
                .message_bus_options = options.message_bus_options,
            });

            // Disable all dynamic allocation from this point onwards.
            self.static_allocator.transition_from_init_to_static();

            initialized = true;
            errdefer self.deinit(allocator);

            // Open the (Forest inside) StateMachine:
            self.opened = false;
            self.state_machine.open(state_machine_open_callback);
            while (!self.opened) {
                // self.grid.tick();
                self.superblock.storage.tick();
            }

            self.opened = false;
            self.journal.recover(journal_recover_callback);
            while (!self.opened) self.superblock.storage.tick();

            if (self.journal.is_empty()) {
                // The data file is brand new — no messages have ever been written.
                // Transition to normal status; no need to run the VSR recovery protocol.
                assert(self.journal.dirty.count == 0);
                assert(self.journal.faulty.count == 0);
                assert(self.commit_min == 0);
                assert(self.commit_max == 0);
                assert(self.op_checkpoint == 0);
                assert(self.op == 0);
                assert(self.view == 0);

                log.debug("{}: open: empty data file", .{self.replica});
                self.transition_to_normal_from_recovering_status(0);
                assert(self.status == .normal);
            } else if (self.replica_count == 1) {
                if (self.journal.faulty.count != 0) @panic("journal is corrupt");
            } else {
                assert(self.status == .recovering);
            }
        }

        fn superblock_open_callback(superblock_context: *SuperBlock.Context) void {
            const self = @fieldParentPtr(Self, "superblock_context", superblock_context);
            assert(!self.opened);
            self.opened = true;
        }

        fn state_machine_open_callback(state_machine: *StateMachine) void {
            const self = @fieldParentPtr(Self, "state_machine", state_machine);
            assert(!self.opened);
            self.opened = true;
        }

        fn journal_recover_callback(journal: *Journal) void {
            const self = @fieldParentPtr(Self, "journal", journal);
            assert(!self.opened);
            self.opened = true;
        }

        const Options = struct {
            cluster: u32,
            replica_count: u8,
            replica_index: u8,
            time: Time,
            storage: *Storage,
            message_pool: *MessagePool,
            // TODO With https://github.com/coilhq/tigerbeetle/issues/71,
            // the separate message_bus_options won't be necessary.
            message_bus_options: MessageBus.Options,
            state_machine_options: StateMachine.Options,
        };

        /// NOTE: self.superblock must be initialized and opened prior to this call.
        fn init(self: *Self, allocator: Allocator, options: Options) !void {
            const replica_count = options.replica_count;
            const replica_index = options.replica_index;
            assert(replica_count > 0);
            assert(replica_index < replica_count);

            assert(self.opened);
            assert(self.superblock.opened);
            assert(self.superblock.working.vsr_state.internally_consistent());

            const quorums = vsr.quorums(replica_count);
            const quorum_replication = quorums.replication;
            const quorum_view_change = quorums.view_change;
            assert(quorum_replication <= replica_count);
            assert(quorum_view_change <= replica_count);
            assert(quorum_view_change + quorum_replication >= replica_count);

            if (replica_count <= 2) {
                assert(quorum_replication == replica_count);
                assert(quorum_view_change == replica_count);
            } else {
                assert(quorum_replication < replica_count);
                assert(quorum_view_change < replica_count);
            }

            // Flexible quorums are safe if these two quorums intersect so that this relation holds:
            assert(quorum_replication + quorum_view_change > replica_count);

            self.time = options.time;
            self.clock = try Clock.init(
                allocator,
                replica_count,
                replica_index,
                &self.time,
            );
            errdefer self.clock.deinit(allocator);

            self.journal = try Journal.init(allocator, options.storage, replica_index);
            errdefer self.journal.deinit(allocator);

            self.message_bus = try MessageBus.init(
                allocator,
                options.cluster,
                .{ .replica = options.replica_index },
                options.message_pool,
                Self.on_message_from_bus,
                options.message_bus_options,
            );
            errdefer self.message_bus.deinit(allocator);

            self.grid = try Grid.init(allocator, &self.superblock);
            errdefer self.grid.deinit(allocator);

            self.state_machine = try StateMachine.init(
                allocator,
                &self.grid,
                options.state_machine_options,
            );
            errdefer self.state_machine.deinit(allocator);

            const recovery_nonce = blk: {
                var nonce: [@sizeOf(Nonce)]u8 = undefined;
                var hash = std.crypto.hash.Blake3.init(.{});
                hash.update(std.mem.asBytes(&self.clock.monotonic()));
                hash.update(&[_]u8{replica_index});
                hash.final(&nonce);
                break :blk @bitCast(Nonce, nonce);
            };

            self.* = Self{
                .static_allocator = self.static_allocator,
                .cluster = options.cluster,
                .replica_count = replica_count,
                .replica = replica_index,
                .quorum_replication = quorum_replication,
                .quorum_view_change = quorum_view_change,
                // Copy the (already-initialized) time back, to avoid regressing the monotonic
                // clock guard.
                .time = self.time,
                .clock = self.clock,
                .journal = self.journal,
                .message_bus = self.message_bus,
                .state_machine = self.state_machine,
                .superblock = self.superblock,
                .grid = self.grid,
                .opened = self.opened,
                .view = self.superblock.working.vsr_state.view,
                .view_normal = self.superblock.working.vsr_state.view_normal,
                .op = 0,
                .op_checkpoint = self.superblock.working.vsr_state.commit_min,
                .commit_min = self.superblock.working.vsr_state.commit_min,
                .commit_max = self.superblock.working.vsr_state.commit_max,
                .ping_timeout = Timeout{
                    .name = "ping_timeout",
                    .id = replica_index,
                    .after = 100,
                },
                .prepare_timeout = Timeout{
                    .name = "prepare_timeout",
                    .id = replica_index,
                    .after = 50,
                },
                .commit_timeout = Timeout{
                    .name = "commit_timeout",
                    .id = replica_index,
                    .after = 100,
                },
                .normal_status_timeout = Timeout{
                    .name = "normal_status_timeout",
                    .id = replica_index,
                    .after = 500,
                },
                .view_change_status_timeout = Timeout{
                    .name = "view_change_status_timeout",
                    .id = replica_index,
                    .after = 500,
                },
                .view_change_message_timeout = Timeout{
                    .name = "view_change_message_timeout",
                    .id = replica_index,
                    .after = 50,
                },
                .repair_timeout = Timeout{
                    .name = "repair_timeout",
                    .id = replica_index,
                    .after = 50,
                },
                .recovery_timeout = Timeout{
                    .name = "recovery_timeout",
                    .id = replica_index,
                    .after = 200,
                },
                .recovery_nonce = recovery_nonce,
                .prng = std.rand.DefaultPrng.init(replica_index),
            };

            log.debug("{}: init: replica_count={} quorum_view_change={} quorum_replication={}", .{
                self.replica,
                self.replica_count,
                self.quorum_view_change,
                self.quorum_replication,
            });

            // To reduce the probability of clustering, for efficient linear probing, the hash map will
            // always overallocate capacity by a factor of two.
            log.debug("{}: init: client_table.capacity()={} for constants.clients_max={} entries", .{
                self.replica,
                self.client_table().capacity(),
                constants.clients_max,
            });

            assert(self.status == .recovering);
        }

        /// Free all memory and unref all messages held by the replica
        /// This does not deinitialize the StateMachine, MessageBus, Storage, or Time
        pub fn deinit(self: *Self, allocator: Allocator) void {
            assert(self.tracer_slot_checkpoint == null);
            assert(self.tracer_slot_commit == null);

            self.static_allocator.transition_from_static_to_deinit();

            self.journal.deinit(allocator);
            self.clock.deinit(allocator);
            self.state_machine.deinit(allocator);
            self.superblock.deinit(allocator);
            self.grid.deinit(allocator);
            defer self.message_bus.deinit(allocator);

            while (self.pipeline.pop()) |prepare| self.message_bus.unref(prepare.message);

            if (self.loopback_queue) |loopback_message| {
                assert(loopback_message.next == null);
                self.message_bus.unref(loopback_message);
                self.loopback_queue = null;
            }

            if (self.commit_prepare) |message| {
                assert(self.committing);
                assert(self.commit_callback != null);
                self.message_bus.unref(message);
                self.commit_prepare = null;
            } else {
                assert(self.commit_callback == null);
            }

            for (self.do_view_change_from_all_replicas) |message| {
                if (message) |m| self.message_bus.unref(m);
            }

            for (self.recovery_response_from_other_replicas) |message| {
                if (message) |m| self.message_bus.unref(m);
            }
        }

        /// The client table records for each client the latest session and the latest committed reply.
        inline fn client_table(self: *Self) *ClientTable {
            return &self.superblock.client_table;
        }

        /// Time is measured in logical ticks that are incremented on every call to tick().
        /// This eliminates a dependency on the system time and enables deterministic testing.
        pub fn tick(self: *Self) void {
            assert(self.opened);
            // Ensure that all asynchronous IO callbacks flushed the loopback queue as needed.
            // If an IO callback queues a loopback message without flushing the queue then this will
            // delay the delivery of messages (e.g. a prepare_ok from the primary to itself) and
            // decrease throughput significantly.
            assert(self.loopback_queue == null);

            // TODO Replica owns Time; should it tick() here instead of Clock?
            self.clock.tick();
            // self.grid.tick();
            self.message_bus.tick();

            if (self.status == .recovering) {
                if (self.recovery_timeout.ticking) {
                    // Continue running the VSR recovery protocol.
                    self.recovery_timeout.tick();
                    if (self.recovery_timeout.fired()) self.on_recovery_timeout();
                } else if (self.replica_count == 1) {
                    // A cluster-of-one does not run the VSR recovery protocol.
                    if (self.committing) return;
                    assert(self.journal.faulty.count == 0);
                    assert(self.op == 0);
                    // TODO Assert that this path isn't taken more than once.
                    self.op = self.journal.op_maximum();
                    assert(self.op >= self.commit_min);
                    assert(self.op >= self.op_checkpoint);
                    assert(self.op <= self.op_checkpoint_trigger());
                    assert(self.journal.header_with_op(self.op) != null);
                    self.commit_journal(self.op);
                    // The recovering→normal transition is deferred until all ops are committed.
                } else {
                    // The journal just finished recovery.
                    // Now try to learn the current view via the VSR recovery protocol.
                    self.recovery_timeout.start();
                    self.recover();
                }
                return;
            }

            self.ping_timeout.tick();
            self.prepare_timeout.tick();
            self.commit_timeout.tick();
            self.normal_status_timeout.tick();
            self.view_change_status_timeout.tick();
            self.view_change_message_timeout.tick();
            self.repair_timeout.tick();

            if (self.ping_timeout.fired()) self.on_ping_timeout();
            if (self.prepare_timeout.fired()) self.on_prepare_timeout();
            if (self.commit_timeout.fired()) self.on_commit_timeout();
            if (self.normal_status_timeout.fired()) self.on_normal_status_timeout();
            if (self.view_change_status_timeout.fired()) self.on_view_change_status_timeout();
            if (self.view_change_message_timeout.fired()) self.on_view_change_message_timeout();
            if (self.repair_timeout.fired()) self.on_repair_timeout();

            // None of the on_timeout() functions above should send a message to this replica.
            assert(self.loopback_queue == null);
        }

        /// Called by the MessageBus to deliver a message to the replica.
        fn on_message_from_bus(message_bus: *MessageBus, message: *Message) void {
            const self = @fieldParentPtr(Self, "message_bus", message_bus);
            self.on_message(message);
        }

        pub fn on_message(self: *Self, message: *Message) void {
            assert(self.opened);
            assert(self.loopback_queue == null);
            assert(message.references > 0);

            log.debug("{}: on_message: view={} status={} {}", .{
                self.replica,
                self.view,
                self.status,
                message.header,
            });

            if (message.header.invalid()) |reason| {
                log.err("{}: on_message: invalid ({s})", .{ self.replica, reason });
                return;
            }

            // No client or replica should ever send a .reserved message.
            assert(message.header.command != .reserved);

            if (message.header.cluster != self.cluster) {
                log.warn("{}: on_message: wrong cluster (cluster must be {} not {})", .{
                    self.replica,
                    self.cluster,
                    message.header.cluster,
                });
                return;
            }

            assert(message.header.replica < self.replica_count);
            switch (message.header.command) {
                .ping => self.on_ping(message),
                .pong => self.on_pong(message),
                .request => self.on_request(message),
                .prepare => self.on_prepare(message),
                .prepare_ok => self.on_prepare_ok(message),
                .commit => self.on_commit(message),
                .start_view_change => self.on_start_view_change(message),
                .do_view_change => self.on_do_view_change(message),
                .start_view => self.on_start_view(message),
                .recovery => self.on_recovery(message),
                .recovery_response => self.on_recovery_response(message),
                .request_start_view => self.on_request_start_view(message),
                .request_prepare => self.on_request_prepare(message),
                .request_headers => self.on_request_headers(message),
                .request_block => unreachable, // TODO
                .headers => self.on_headers(message),
                .nack_prepare => self.on_nack_prepare(message),
                // A replica should never handle misdirected messages intended for a client:
                .eviction, .reply => {
                    log.warn("{}: on_message: ignoring misdirected {s} message", .{
                        self.replica,
                        @tagName(message.header.command),
                    });
                    return;
                },
                .block => unreachable, // TODO
                .reserved => unreachable,
            }

            if (self.loopback_queue) |loopback_message| {
                log.err("{}: on_message: on_{s}() queued a {s} loopback message with no flush", .{
                    self.replica,
                    @tagName(message.header.command),
                    @tagName(loopback_message.header.command),
                });
            }

            // Any message handlers that loopback must take responsibility for the flush.
            assert(self.loopback_queue == null);

            // We have to regularly flush the tracer to get output from short benchmarks.
            tracer.flush();
        }

        fn on_ping(self: *Self, message: *const Message) void {
            if (self.status != .normal and self.status != .view_change) return;

            assert(self.status == .normal or self.status == .view_change);

            // TODO Drop pings that were not addressed to us.

            var pong = Header{
                .command = .pong,
                .cluster = self.cluster,
                .replica = self.replica,
                .view = self.view,
            };

            if (message.header.client > 0) {
                assert(message.header.replica == 0);

                // We must only ever send our view number to a client via a pong message if we are
                // in normal status. Otherwise, we may be partitioned from the cluster with a newer
                // view number, leak this to the client, which would then pass this to the cluster
                // in subsequent client requests, which would then ignore these client requests with
                // a newer view number, locking out the client. The principle here is that we must
                // never send view numbers for views that have not yet started.
                if (self.status == .normal) {
                    self.send_header_to_client(message.header.client, pong);
                }
            } else if (message.header.replica == self.replica) {
                log.warn("{}: on_ping: ignoring (self)", .{self.replica});
            } else {
                // Copy the ping's monotonic timestamp to our pong and add our wall clock sample:
                pong.op = message.header.op;
                pong.timestamp = @bitCast(u64, self.clock.realtime());
                self.send_header_to_replica(message.header.replica, pong);
            }
        }

        fn on_pong(self: *Self, message: *const Message) void {
            if (message.header.client > 0) return;
            if (message.header.replica == self.replica) return;

            const m0 = message.header.op;
            const t1 = @bitCast(i64, message.header.timestamp);
            const m2 = self.clock.monotonic();

            self.clock.learn(message.header.replica, m0, t1, m2);
        }

        /// The primary advances op-number, adds the request to the end of the log, and updates the
        /// information for this client in the client-table to contain the new request number, s.
        /// Then it sends a ⟨PREPARE v, m, n, k⟩ message to the other replicas, where v is the
        /// current view-number, m is the message it received from the client, n is the op-number
        /// it assigned to the request, and k is the commit-number.
        fn on_request(self: *Self, message: *Message) void {
            if (self.ignore_request_message(message)) return;

            assert(self.status == .normal);
            assert(self.primary());
            assert(self.commit_min == self.commit_max);
            assert(self.commit_max + self.pipeline.count == self.op);

            assert(message.header.command == .request);
            assert(message.header.view <= self.view); // The client's view may be behind ours.

            const realtime = self.clock.realtime_synchronized() orelse {
                log.err("{}: on_request: dropping (clock not synchronized)", .{self.replica});
                return;
            };

            log.debug("{}: on_request: request {}", .{ self.replica, message.header.checksum });

            // Guard against the wall clock going backwards by taking the max with timestamps issued:
            self.state_machine.prepare_timestamp = std.math.max(
                // The cluster `commit_timestamp` may be ahead of our `prepare_timestamp` because this
                // may be our first prepare as a recently elected primary:
                std.math.max(
                    self.state_machine.prepare_timestamp,
                    self.state_machine.commit_timestamp,
                ) + 1,
                @intCast(u64, realtime),
            );
            assert(self.state_machine.prepare_timestamp > self.state_machine.commit_timestamp);

            const prepare_timestamp = self.state_machine.prepare(
                message.header.operation.cast(StateMachine),
                message.body(),
            );

            const latest_entry = self.journal.header_with_op(self.op).?;
            message.header.parent = latest_entry.checksum;
            message.header.context = message.header.checksum;
            message.header.view = self.view;
            message.header.op = self.op + 1;
            message.header.commit = self.commit_max;
            message.header.timestamp = prepare_timestamp;
            message.header.replica = self.replica;
            message.header.command = .prepare;

            message.header.set_checksum_body(message.body());
            message.header.set_checksum();

            log.debug("{}: on_request: prepare {}", .{ self.replica, message.header.checksum });

            self.pipeline.push_assume_capacity(.{ .message = message.ref() });
            assert(self.pipeline.count >= 1);

            if (self.pipeline.count == 1) {
                // This is the only prepare in the pipeline, start the timeout:
                assert(!self.prepare_timeout.ticking);
                self.prepare_timeout.start();
            } else {
                // Do not restart the prepare timeout as it is already ticking for another prepare.
                assert(self.prepare_timeout.ticking);
                const previous = self.pipeline.get_ptr(self.pipeline.count - 2).?;
                assert(previous.message.header.checksum == message.header.parent);
            }

            self.on_prepare(message);

            // We expect `on_prepare()` to increment `self.op` to match the primary's latest prepare:
            // This is critical to ensure that pipelined prepares do not receive the same op number.
            assert(self.op == message.header.op);
        }

        /// Replication is simple, with a single code path for the primary and backups.
        ///
        /// The primary starts by sending a prepare message to itself.
        ///
        /// Each replica (including the primary) then forwards this prepare message to the next
        /// replica in the configuration, in parallel to writing to its own journal, closing the
        /// circle until the next replica is back to the primary, in which case the replica does not
        /// forward.
        ///
        /// This keeps the primary's outgoing bandwidth limited (one-for-one) to incoming bandwidth,
        /// since the primary need only replicate to the next replica. Otherwise, the primary would
        /// need to replicate to multiple backups, dividing available bandwidth.
        ///
        /// This does not impact latency, since with Flexible Paxos we need only one remote
        /// prepare_ok. It is ideal if this synchronous replication to one remote replica is to the
        /// next replica, since that is the replica next in line to be primary, which will need to
        /// be up-to-date before it can start the next view.
        ///
        /// At the same time, asynchronous replication keeps going, so that if our local disk is
        /// slow, then any latency spike will be masked by more remote prepare_ok messages as they
        /// come in. This gives automatic tail latency tolerance for storage latency spikes.
        ///
        /// The remaining problem then is tail latency tolerance for network latency spikes.
        /// If the next replica is down or partitioned, then the primary's prepare timeout will fire,
        /// and the primary will resend but to another replica, until it receives enough prepare_ok's.
        fn on_prepare(self: *Self, message: *Message) void {
            self.view_jump(message.header);

            if (self.is_repair(message)) {
                log.debug("{}: on_prepare: ignoring (repair)", .{self.replica});
                self.on_repair(message);
                return;
            }

            if (self.status != .normal) {
                log.debug("{}: on_prepare: ignoring ({})", .{ self.replica, self.status });
                return;
            }

            if (message.header.view < self.view) {
                log.debug("{}: on_prepare: ignoring (older view)", .{self.replica});
                return;
            }

            if (message.header.view > self.view) {
                log.debug("{}: on_prepare: ignoring (newer view)", .{self.replica});
                return;
            }

            // Verify that the new request will fit in the WAL.
            if (message.header.op > self.op_checkpoint_trigger()) {
                log.debug("{}: on_prepare: ignoring op={} (too far ahead, checkpoint={})", .{
                    self.replica,
                    message.header.op,
                    self.op_checkpoint,
                });
                // When we are the primary, `on_request` enforces this invariant.
                assert(self.backup());
                return;
            }

            assert(self.status == .normal);
            assert(message.header.view == self.view);
            assert(self.primary() or self.backup());
            assert(message.header.replica == self.primary_index(message.header.view));
            assert(message.header.op > self.op_checkpoint);
            assert(message.header.op > self.op);
            assert(message.header.op > self.commit_min);
            assert(message.header.op <= self.op_checkpoint_trigger());

            if (self.backup()) self.normal_status_timeout.reset();

            if (message.header.op > self.op + 1) {
                log.debug("{}: on_prepare: newer op", .{self.replica});
                self.jump_to_newer_op_in_normal_status(message.header);
                // "`replica.op` exists" invariant is temporarily broken.
                assert(self.journal.header_with_op(message.header.op - 1) == null);
            }

            if (self.journal.previous_entry(message.header)) |previous| {
                // Any previous entry may be a whole journal's worth of ops behind due to wrapping.
                // We therefore do not do any further op or checksum assertions beyond this:
                self.panic_if_hash_chain_would_break_in_the_same_view(previous, message.header);
            }

            // We must advance our op and set the header as dirty before replicating and journalling.
            // The primary needs this before its journal is outrun by any prepare_ok quorum:
            log.debug("{}: on_prepare: advancing: op={}..{} checksum={}..{}", .{
                self.replica,
                self.op,
                message.header.op,
                message.header.parent,
                message.header.checksum,
            });
            assert(message.header.op == self.op + 1);
            self.op = message.header.op;
            self.journal.set_header_as_dirty(message.header);

            self.replicate(message);
            self.append(message);

            if (self.backup()) {
                // A prepare may already be committed if requested by repair() so take the max:
                self.commit_journal(std.math.max(message.header.commit, self.commit_max));
                assert(self.commit_max >= message.header.commit);
            }
        }

        fn on_prepare_ok(self: *Self, message: *Message) void {
            if (self.ignore_prepare_ok(message)) return;

            assert(self.status == .normal);
            assert(message.header.view == self.view);
            assert(self.primary());

            const prepare = self.pipeline_prepare_for_prepare_ok(message) orelse return;

            assert(prepare.message.header.checksum == message.header.context);
            assert(prepare.message.header.op >= self.commit_max + 1);
            assert(prepare.message.header.op <= self.commit_max + self.pipeline.count);
            assert(prepare.message.header.op <= self.op);

            // Wait until we have `f + 1` prepare_ok messages (including ourself) for quorum:
            // const threshold = self.quorum_replication;
            // TODO: When Block recover & state transfer are implemented, this can be removed.
            const threshold =
                if (prepare.message.header.op == self.op_checkpoint_trigger() or
                prepare.message.header.op == self.op_checkpoint + constants.lsm_batch_multiple + 1)
                self.replica_count
            else
                self.quorum_replication;

            const count = self.count_message_and_receive_quorum_exactly_once(
                &prepare.ok_from_all_replicas,
                message,
                threshold,
            ) orelse return;

            assert(count == threshold);
            assert(!prepare.ok_quorum_received);
            prepare.ok_quorum_received = true;

            log.debug("{}: on_prepare_ok: quorum received, context={}", .{
                self.replica,
                prepare.message.header.checksum,
            });

            self.commit_pipeline();
        }

        /// Known issue:
        /// TODO The primary should stand down if it sees too many retries in on_prepare_timeout().
        /// It's possible for the network to be one-way partitioned so that backups don't see the
        /// primary as down, but neither can the primary hear from the backups.
        fn on_commit(self: *Self, message: *const Message) void {
            self.view_jump(message.header);

            if (self.status != .normal) {
                log.debug("{}: on_commit: ignoring ({})", .{ self.replica, self.status });
                return;
            }

            if (message.header.view < self.view) {
                log.debug("{}: on_commit: ignoring (older view)", .{self.replica});
                return;
            }

            if (message.header.view > self.view) {
                log.debug("{}: on_commit: ignoring (newer view)", .{self.replica});
                return;
            }

            if (self.primary()) {
                log.warn("{}: on_commit: ignoring (primary)", .{self.replica});
                return;
            }

            assert(self.status == .normal);
            assert(self.backup());
            assert(message.header.view == self.view);
            assert(message.header.replica == self.primary_index(message.header.view));

            // We may not always have the latest commit entry but if we do our checksum must match:
            if (self.journal.header_with_op(message.header.commit)) |commit_entry| {
                if (commit_entry.checksum == message.header.context) {
                    log.debug("{}: on_commit: checksum verified", .{self.replica});
                } else if (self.valid_hash_chain("on_commit")) {
                    @panic("commit checksum verification failed");
                } else {
                    // We may still be repairing after receiving the start_view message.
                    log.debug("{}: on_commit: skipping checksum verification", .{self.replica});
                }
            }

            self.normal_status_timeout.reset();
            self.commit_journal(message.header.commit);
        }

        fn on_repair(self: *Self, message: *Message) void {
            assert(message.header.command == .prepare);

            if (self.status != .normal and self.status != .view_change) {
                log.debug("{}: on_repair: ignoring ({})", .{ self.replica, self.status });
                return;
            }

            if (message.header.view > self.view) {
                log.debug("{}: on_repair: ignoring (newer view)", .{self.replica});
                return;
            }

            if (self.status == .view_change and message.header.view == self.view) {
                log.debug("{}: on_repair: ignoring (view started)", .{self.replica});
                return;
            }

            if (self.status == .view_change and self.primary_index(self.view) != self.replica) {
                log.debug("{}: on_repair: ignoring (view change, backup)", .{self.replica});
                return;
            }

            if (self.status == .view_change and !self.do_view_change_quorum) {
                log.debug("{}: on_repair: ignoring (view change, waiting for quorum)", .{
                    self.replica,
                });
                return;
            }

            if (message.header.op > self.op) {
                assert(message.header.view < self.view);
                log.debug("{}: on_repair: ignoring (would advance self.op)", .{self.replica});
                return;
            }

            assert(self.status == .normal or self.status == .view_change);
            assert(self.repairs_allowed());
            assert(message.header.view <= self.view);
            assert(message.header.op <= self.op); // Repairs may never advance `self.op`.

            if (self.journal.has_clean(message.header)) {
                log.debug("{}: on_repair: ignoring (duplicate)", .{self.replica});

                self.send_prepare_ok(message.header);
                defer self.flush_loopback_queue();
                return;
            }

            if (self.repair_header(message.header)) {
                assert(self.journal.has_dirty(message.header));

                if (self.nack_prepare_op) |nack_prepare_op| {
                    if (nack_prepare_op == message.header.op) {
                        log.debug("{}: on_repair: repairing uncommitted op={}", .{
                            self.replica,
                            message.header.op,
                        });
                        self.reset_quorum_nack_prepare();
                    }
                }

                log.debug("{}: on_repair: repairing journal", .{self.replica});
                self.write_prepare(message, .repair);
            }
        }

        fn on_start_view_change(self: *Self, message: *Message) void {
            if (self.ignore_view_change_message(message)) return;

            assert(self.status == .normal or self.status == .view_change);
            assert(message.header.view >= self.view);
            assert(message.header.replica != self.replica);

            self.view_jump(message.header);

            assert(self.status == .view_change);
            assert(message.header.view == self.view);

            // Wait until we have `f` messages (excluding ourself) for quorum:
            assert(self.replica_count > 1);
            const threshold = self.quorum_view_change - 1;

            const count = self.count_message_and_receive_quorum_exactly_once(
                &self.start_view_change_from_other_replicas,
                message,
                threshold,
            ) orelse return;

            assert(count == threshold);
            assert(!self.start_view_change_from_other_replicas.isSet(self.replica));
            log.debug("{}: on_start_view_change: view={} quorum received", .{
                self.replica,
                self.view,
            });

            assert(!self.start_view_change_quorum);
            assert(!self.do_view_change_quorum);
            self.start_view_change_quorum = true;

            // When replica i receives start_view_change messages for its view from f other replicas,
            // it sends a ⟨do_view_change v, l, v’, n, k, i⟩ message to the node that will be the
            // primary in the new view. Here v is its view, l is its log, v′ is the view number of the
            // latest view in which its status was normal, n is the op number, and k is the commit
            // number.
            self.send_do_view_change();
            defer self.flush_loopback_queue();
        }

        /// When the new primary receives f + 1 do_view_change messages from different replicas
        /// (including itself), it sets its view number to that in the messages and selects as the
        /// new log the one contained in the message with the largest v′; if several messages have
        /// the same v′ it selects the one among them with the largest n. It sets its op number to
        /// that of the topmost entry in the new log, sets its commit number to the largest such
        /// number it received in the do_view_change messages, changes its status to normal, and
        /// informs the other replicas of the completion of the view change by sending
        /// ⟨start_view v, l, n, k⟩ messages to the other replicas, where l is the new log, n is the
        /// op number, and k is the commit number.
        ///
        /// For each DVC in the quorum:
        ///
        /// * The headers must all belong to the same hash chain. (Gaps are allowed).
        ///   (Reason: the headers bundled with the DVC(s) with the highest view_normal will be
        ///   loaded into the new primary with `replace_header()`, not `repair_header()`).
        ///
        /// Across all DVCs in the quorum:
        ///
        /// * The headers of every DVC with the same view_normal must agree. In other words:
        ///   dvc₁.headers[i].op == dvc₂.headers[j].op implies
        ///   dvc₁.headers[i].checksum == dvc₂.headers[j].checksum.
        ///   (Reason: the headers bundled with the DVC(s) with the highest view_normal will be
        ///   loaded into the new primary with `replace_header()`, not `repair_header()`).
        ///
        /// Perhaps unintuitively, it is safe to advertise a header before its message is prepared
        /// (e.g. the write is still queued). The header is either:
        ///
        /// * committed — so another replica in the quorum must have a copy, according to the quorum
        ///   intersection property. Or,
        /// * uncommitted — if the header is chosen, but cannot be recovered from any replica, then
        ///   it will be discarded by the nack protocol.
        fn on_do_view_change(self: *Self, message: *Message) void {
            if (self.ignore_view_change_message(message)) return;

            assert(self.status == .normal or self.status == .view_change);
            assert(message.header.view >= self.view);
            assert(self.primary_index(message.header.view) == self.replica);

            self.view_jump(message.header);

            assert(self.status == .view_change);
            assert(message.header.view == self.view);

            // We may receive a `do_view_change` quorum from other replicas, which already have a
            // `start_view_change_quorum`, before we receive a `start_view_change_quorum`:
            if (!self.start_view_change_quorum) {
                log.debug("{}: on_do_view_change: waiting for start_view_change quorum (view={})", .{
                    self.replica,
                    self.view,
                });
                return;
            }

            // Wait until we have `f + 1` messages (including ourself) for quorum:
            assert(self.replica_count > 1);
            const threshold = self.quorum_view_change;

            const count = self.reference_message_and_receive_quorum_exactly_once(
                &self.do_view_change_from_all_replicas,
                message,
                threshold,
            ) orelse return;

            assert(count == threshold);
            assert(self.do_view_change_from_all_replicas[self.replica] != null);
            log.debug("{}: on_do_view_change: view={} quorum received", .{
                self.replica,
                self.view,
            });

            assert(self.start_view_change_quorum);
            assert(!self.do_view_change_quorum);
            self.do_view_change_quorum = true;

            self.primary_set_log_from_do_view_change_messages();
            assert(self.op >= self.commit_max);
            assert(self.state_machine.prepare_timestamp >=
                self.journal.header_with_op(self.op).?.timestamp);

            // Start repairs according to the CTRL protocol:
            assert(!self.repair_timeout.ticking);
            self.repair_timeout.start();
            self.repair();
        }

        /// When other replicas receive the start_view message, they replace their log with the one
        /// in the message, set their op number to that of the latest entry in the log, set their
        /// view number to the view number in the message, change their status to normal, and update
        /// the information in their client table. If there are non-committed operations in the log,
        /// they send a ⟨prepare_ok v, n, i⟩ message to the primary; here n is the op-number. Then
        /// they execute all operations known to be committed that they haven’t executed previously,
        /// advance their commit number, and update the information in their client table.
        fn on_start_view(self: *Self, message: *const Message) void {
            if (self.ignore_view_change_message(message)) return;

            if (message.header.op > self.op_checkpoint_trigger()) {
                // This replica is too far behind, i.e. the new `self.op` is too far ahead of the
                // last checkpoint. If we wrap now, we overwrite un-checkpointed transfers in the WAL,
                // precluding recovery.
                //
                // TODO State transfer. Currently this is unreachable because the
                // primary won't checkpoint until all replicas are caught up.
                unreachable;
            }

            assert(self.status == .view_change or self.status == .normal);
            assert(message.header.view >= self.view);
            assert(message.header.replica != self.replica);
            assert(message.header.replica == self.primary_index(message.header.view));

            self.view_jump(message.header);

            assert(self.status == .view_change);
            assert(message.header.view == self.view);
            assert(message.header.op == op_highest(message_body_as_headers(message)));

            self.set_op_and_commit_max(message.header.op, message.header.commit, "on_start_view");
            self.replace_headers(message_body_as_headers(message));

            assert(self.op == message.header.op);

            if (self.status == .view_change) {
                self.transition_to_normal_from_view_change_status(message.header.view);
                self.send_prepare_oks_after_view_change();
            }

            assert(self.status == .normal);
            assert(message.header.view == self.view);
            assert(self.backup());

            self.commit_journal(self.commit_max);

            self.repair();
        }

        fn on_request_start_view(self: *Self, message: *const Message) void {
            if (self.ignore_repair_message(message)) return;

            assert(self.status == .normal);
            assert(message.header.view == self.view);
            assert(message.header.replica != self.replica);
            assert(self.primary());

            const start_view = self.create_view_change_message(.start_view);
            defer self.message_bus.unref(start_view);

            assert(start_view.references == 1);
            assert(start_view.header.command == .start_view);
            assert(start_view.header.view == self.view);
            assert(start_view.header.op == self.op);
            assert(start_view.header.commit == self.commit_max);

            self.send_message_to_replica(message.header.replica, start_view);
        }

        fn on_recovery(self: *Self, message: *const Message) void {
            assert(self.replica_count > 1);

            if (self.status != .normal) {
                log.debug("{}: on_recovery: ignoring ({})", .{ self.replica, self.status });
                return;
            }

            if (message.header.replica == self.replica) {
                log.warn("{}: on_recovery: ignoring (self)", .{self.replica});
                return;
            }

            const response = self.message_bus.get_message();
            defer self.message_bus.unref(response);

            log.debug("{}: on_recovery: view={} op={} commit={} nonce={}", .{
                self.replica,
                self.view,
                self.op,
                self.commit_max,
                message.header.context,
            });

            response.header.* = .{
                .command = .recovery_response,
                .cluster = self.cluster,
                .context = message.header.context, // Echo the request's nonce.
                .replica = self.replica,
                .view = self.view,
                .op = self.op,
                .commit = self.commit_max,
            };

            // A recovery response attaches at least as many headers as a DVC message attaches.
            // To understand why, consider this scenario, where:
            //
            //                   replica_count   3
            //      do_view_change.headers.len   3 (= pipeline_max)
            //   recovery_response.headers.len   2 (!)
            //                   replica 0 log   3, 4a, 5a, 6a, 7a, 8a  (status=normal, primary)
            //                   replica 1 log   3, 4a, 5a, --, --, --  (status=normal, backup)
            //                   replica 2 log   3, 4b, 5b, --, --, --  (status=recovering)
            //
            // 1. Replica 2 receives a recovery_response quorum.
            // 2. Replica 2 sets `replica.op` to 8a.
            // 3. Replica 2 sets its headers from the primary's recovery_response (8a, 7a)
            //    (via `replace_header()`).
            // 4. Replica 2 transitions to status=normal.
            // 5. Replica 0 fails (before replica 2 has a chance to repair its hash chain.)
            // 6. Replica 1 initiates a view change.
            // 7. Replica 1 collects a DVC quorum:
            //      replica 1:  3, 4a, 5a (view_normal=latest)
            //      replica 2: 5b, 7a, 8a (view_normal=latest)
            //    Replicas 1 and 2 share the highest view_normal, so both sets of headers are canonical.
            // 8. Replica 1 loads the canonical headers (via `replace_header()`) from both DVCs.
            //    Messages 8a and 7a will be dropped via `do_view_change_op_max()` (due to the
            //    gap at op 6). But there is a conflict at op=5. For correctness, replica 1 must
            //    pick 5a — 5a may be committed by replica 0.
            //    Without replica 0's assistance, replica 1 has no way to pick between 5a/5b.
            //
            // Including at least as many headers in the recovery response as the DVC maintains the
            // invariant: DVCs with the same view_normal must never disagree on the identity of a
            // message.
            //
            // (DVCs can still safely include gaps — but they must be of the form [4a,__,6a],
            // not [4a,__,6b]).
            const count = self.copy_latest_headers_and_set_size(
                0,
                self.op,
                view_change_headers_count,
                response,
            );
            assert(count > 0); // We expect that self.op always exists.
            assert(@divExact(response.header.size, @sizeOf(Header)) == 1 + count);

            response.header.set_checksum_body(response.body());
            response.header.set_checksum();

            assert(self.status == .normal);
            // The checksum for a recovery message is deterministic, and cannot be used as a nonce:
            assert(response.header.context != message.header.checksum);

            self.send_message_to_replica(message.header.replica, response);
        }

        fn on_recovery_response(self: *Self, message: *Message) void {
            assert(self.replica_count > 1);

            if (self.status != .recovering) {
                log.debug("{}: on_recovery_response: ignoring ({})", .{
                    self.replica,
                    self.status,
                });
                return;
            }

            if (message.header.replica == self.replica) {
                log.warn("{}: on_recovery_response: ignoring (self)", .{self.replica});
                return;
            }

            if (message.header.context != self.recovery_nonce) {
                log.warn("{}: on_recovery_response: ignoring (different nonce)", .{self.replica});
                return;
            }

            var responses: *QuorumMessages = &self.recovery_response_from_other_replicas;
            if (responses[message.header.replica]) |existing| {
                assert(message.header.replica == existing.header.replica);

                if (message.header.checksum == existing.header.checksum) {
                    // The response was replayed by the network; ignore it.
                    log.debug("{}: on_recovery_response: ignoring (duplicate message)", .{
                        self.replica,
                    });
                    return;
                }

                // We received a second (distinct) response from a replica. Possible causes:
                // * We retried the `recovery` message, because we had not yet received a quorum.
                // * The `recovery` message was duplicated/misdirected by the network, and the
                //   receiver's state changed in the mean time.

                log.debug(
                    "{}: on_recovery_response: replacing response replica={} view={}..{} op={}..{} commit={}..{}",
                    .{
                        self.replica,
                        existing.header.replica,
                        existing.header.view,
                        message.header.view,
                        existing.header.op,
                        message.header.op,
                        existing.header.commit,
                        message.header.commit,
                    },
                );

                if (message.header.view < existing.header.view or
                    (message.header.view == existing.header.view and
                    message.header.op < existing.header.op) or
                    (message.header.view == existing.header.view and
                    message.header.op == existing.header.op and
                    message.header.commit < existing.header.commit))
                {
                    // The second message is older than the first one (reordered packets).
                    log.debug("{}: on_recovery_response: ignoring (older)", .{self.replica});
                    return;
                }

                // The second message is newer than the first one.
                assert(message.header.view >= existing.header.view);
                // The op number may regress if an uncommitted op was discarded in a higher view.
                assert(message.header.op >= existing.header.op or
                    message.header.view > existing.header.view);
                assert(message.header.commit >= existing.header.commit);

                self.message_bus.unref(existing);
                responses[message.header.replica] = null;
            } else {
                log.debug(
                    "{}: on_recovery_response: replica={} view={} op={} commit={}",
                    .{
                        self.replica,
                        message.header.replica,
                        message.header.view,
                        message.header.op,
                        message.header.commit,
                    },
                );
            }

            assert(responses[message.header.replica] == null);
            responses[message.header.replica] = message.ref();

            // Wait until we have:
            // * at least `f + 1` messages for quorum (not including ourself), and
            // * a response from the primary of the highest discovered view.
            const count = self.count_quorum(responses, .recovery_response, self.recovery_nonce);
            assert(count <= self.replica_count - 1);

            const threshold = self.quorum_view_change;
            if (count < threshold) {
                log.debug("{}: on_recovery_response: waiting for quorum ({}/{})", .{
                    self.replica,
                    count,
                    threshold,
                });
                return;
            }

            const view = blk: { // The latest known view.
                var view: u32 = 0;
                for (self.recovery_response_from_other_replicas) |received, replica| {
                    if (received) |response| {
                        assert(replica != self.replica);
                        assert(response.header.replica == replica);
                        assert(response.header.context == self.recovery_nonce);

                        view = std.math.max(view, response.header.view);
                    }
                }
                break :blk view;
            };

            const primary_response = responses[self.primary_index(view)];
            if (primary_response == null) {
                log.debug(
                    "{}: on_recovery_response: ignoring (awaiting response from primary of view={})",
                    .{
                        self.replica,
                        view,
                    },
                );
                return;
            }

            if (primary_response.?.header.view != view) {
                // The primary (according to the view quorum) isn't the primary (according to itself).
                // The `recovery_timeout` will retry shortly with another round.
                log.debug(
                    "{}: on_recovery_response: ignoring (primary view={} != quorum view={})",
                    .{
                        self.replica,
                        primary_response.?.header.view,
                        view,
                    },
                );
                return;
            }

            // This recovering→normal status transition occurs exactly once.
            // All further `recovery_response` messages are ignored.

            // TODO When the view is recovered from the superblock (instead of via the VSR recovery
            // protocol), if the view number indicates that this replica is a primary, it must
            // transition to status=view_change instead of status=normal.

            const primary_headers = message_body_as_headers(primary_response.?);
            assert(primary_headers.len > 0);

            const commit = primary_response.?.header.commit;
            {
                const op = op_highest(primary_headers);
                assert(op == primary_response.?.header.op);

                self.set_op_and_commit_max(op, commit, "on_recovery_response");

                // TODO If the view's primary is >1 WAL ahead of us, these headers could cause
                // problems. We don't want to jump this far ahead to repair, but we still need to
                // use the hash chain to figure out which headers to request. Maybe include our
                // `op_checkpoint` in the recovery (request) message so that the response can give
                // more useful (i.e. older) headers.
                self.replace_headers(primary_headers);

                if (self.op < constants.journal_slot_count) {
                    if (self.journal.header_with_op(0)) |header| {
                        assert(header.command == .prepare);
                        assert(header.operation == .root);
                    } else {
                        // This is the first wrap of the log, and the root prepare is corrupt.
                        // Repair the root repair. This is necessary to maintain the invariant that
                        // the op=commit_min exists in-memory.
                        //
                        // op=0 wouldn't have been repaired by replace_headers above, because it is
                        // already "checkpointed".
                        const header = Header.root_prepare(self.cluster);
                        self.journal.set_header_as_dirty(&header);
                        log.debug("{}: on_recovery_response: repair root op", .{self.replica});
                    }
                }

                assert(self.op == op);
                assert(self.journal.header_with_op(self.op) != null);
            }

            assert(self.status == .recovering);
            self.transition_to_normal_from_recovering_status(view);
            assert(self.status == .normal);
            assert(self.backup());

            log.info("{}: on_recovery_response: recovery done responses={} view={} headers={}..{}" ++
                " commit={} dirty={} faulty={}", .{
                self.replica,
                count,
                view,
                primary_headers[primary_headers.len - 1].op,
                primary_headers[0].op,
                commit,
                self.journal.dirty.count,
                self.journal.faulty.count,
            });

            self.state_machine.prepare_timestamp = self.journal.header_with_op(self.op).?.timestamp;
            // `state_machine.commit_timestamp` is updated as messages are committed.

            self.reset_quorum_recovery_response();
            self.commit_journal(commit);
            self.repair();
        }

        /// If the requested prepare has been guaranteed by this replica:
        /// * Read the prepare from storage, and forward it to the replica that requested it.
        /// * Otherwise send no reply — it isn't safe to nack.
        /// If the requested prepare has *not* been guaranteed by this replica, then send a nack.
        ///
        /// A prepare is considered "guaranteed" by a replica if that replica has acknowledged it
        /// to the cluster. The cluster sees the replica as an underwriter of a guaranteed
        /// prepare. If a guaranteed prepare is found to by faulty, the replica must repair it
        /// to restore durability.
        fn on_request_prepare(self: *Self, message: *const Message) void {
            if (self.ignore_repair_message(message)) return;

            assert(self.replica_count > 1);
            assert(self.status == .normal or self.status == .view_change);
            assert(message.header.view == self.view);
            assert(message.header.replica != self.replica);

            const op = message.header.op;
            const slot = self.journal.slot_for_op(op);
            const checksum: ?u128 = switch (message.header.timestamp) {
                0 => null,
                1 => message.header.context,
                else => unreachable,
            };

            // Only the primary may respond to `request_prepare` messages without a checksum.
            assert(checksum != null or self.primary_index(self.view) == self.replica);

            // Try to serve the message directly from the pipeline.
            // This saves us from going to disk. And we don't need to worry that the WAL's copy
            // of an uncommitted prepare is lost/corrupted.
            if (self.pipeline_prepare_for_op_and_checksum(op, checksum)) |prepare| {
                log.debug("{}: on_request_prepare: op={} checksum={} reply from pipeline", .{
                    self.replica,
                    op,
                    checksum,
                });
                self.send_message_to_replica(message.header.replica, prepare.message);
                return;
            }

            if (self.journal.prepare_inhabited[slot.index]) {
                const prepare_checksum = self.journal.prepare_checksums[slot.index];
                // Consult `journal.prepare_checksums` (rather than `journal.headers`):
                // the former may have the prepare we want — even if journal recovery marked the
                // slot as faulty and left the in-memory header as reserved.
                if (checksum == null or checksum.? == prepare_checksum) {
                    log.debug("{}: on_request_prepare: op={} checksum={} reading", .{
                        self.replica,
                        op,
                        checksum,
                    });

                    // Improve availability by calling `read_prepare_with_op_and_checksum` instead
                    // of `read_prepare` — even if `journal.headers` contains the target message.
                    // The latter skips the read when the target prepare is present but dirty (e.g.
                    // it was recovered with decision=fix).
                    // TODO Do not reissue the read if we are already reading in order to send to
                    // this particular destination replica.
                    self.journal.read_prepare_with_op_and_checksum(
                        on_request_prepare_read,
                        op,
                        prepare_checksum,
                        message.header.replica,
                    );

                    // We have guaranteed the prepare (not safe to nack).
                    // Our copy may or may not be valid, but we will try to read & forward it.
                    return;
                }
            }

            {
                // We may have guaranteed the prepare but our copy is faulty (not safe to nack).
                if (self.journal.faulty.bit(slot)) return;
                if (self.journal.header_with_op_and_checksum(message.header.op, checksum)) |_| {
                    if (self.journal.dirty.bit(slot)) {
                        // We know of the prepare but have yet to write it (safe to nack).
                        // Continue through below...
                    } else {
                        // We have guaranteed the prepare and our copy is clean (not safe to nack).
                        return;
                    }
                }
            }

            // Protocol-Aware Recovery's CTRL protocol only runs during the view change, when the
            // new primary needs to repair its own WAL before starting the new view.
            //
            // This branch is only where the backup doesn't have the prepare and could possibly
            // send a nack as part of the CTRL protocol. Nacks only get sent during a view change
            // to help the new primary trim uncommitted ops that couldn't otherwise be repaired.
            // Without doing this, the cluster would become permanently unavailable. So backups
            // shouldn't respond to the `request_prepare` if the new view has already started,
            // they should also be in view change status, waiting for the new primary to start
            // the view.
            if (self.status == .view_change) {
                assert(message.header.replica == self.primary_index(self.view));
                assert(checksum != null);

                if (self.journal.header_with_op_and_checksum(op, checksum)) |_| {
                    assert(self.journal.dirty.bit(slot) and !self.journal.faulty.bit(slot));
                }

                if (self.journal.prepare_inhabited[slot.index]) {
                    assert(self.journal.prepare_checksums[slot.index] != checksum.?);
                }

                log.debug("{}: on_request_prepare: op={} checksum={} nacking", .{
                    self.replica,
                    op,
                    checksum,
                });

                self.send_header_to_replica(message.header.replica, .{
                    .command = .nack_prepare,
                    .context = checksum.?,
                    .cluster = self.cluster,
                    .replica = self.replica,
                    .view = self.view,
                    .op = op,
                });
            }
        }

        fn on_request_prepare_read(self: *Self, prepare: ?*Message, destination_replica: ?u8) void {
            const message = prepare orelse {
                log.debug("{}: on_request_prepare_read: prepare=null", .{self.replica});
                return;
            };

            log.debug("{}: on_request_prepare_read: op={} checksum={} sending to replica={}", .{
                self.replica,
                message.header.op,
                message.header.checksum,
                destination_replica.?,
            });

            assert(destination_replica.? != self.replica);
            self.send_message_to_replica(destination_replica.?, message);
        }

        fn on_request_headers(self: *Self, message: *const Message) void {
            if (self.ignore_repair_message(message)) return;

            assert(self.status == .normal or self.status == .view_change);
            assert(message.header.view == self.view);
            assert(message.header.replica != self.replica);

            const response = self.message_bus.get_message();
            defer self.message_bus.unref(response);

            response.header.* = .{
                .command = .headers,
                // We echo the context back to the replica so that they can match up our response:
                .context = message.header.context,
                .cluster = self.cluster,
                .replica = self.replica,
                .view = self.view,
            };

            const op_min = message.header.commit;
            const op_max = message.header.op;
            assert(op_max >= op_min);

            const count = self.copy_latest_headers_and_set_size(op_min, op_max, null, response);
            assert(count >= 0);
            assert(@divExact(response.header.size, @sizeOf(Header)) == 1 + count);

            if (count == 0) {
                log.debug("{}: on_request_headers: ignoring (op={}..{}, no headers)", .{
                    self.replica,
                    op_min,
                    op_max,
                });
                return;
            }

            response.header.set_checksum_body(response.body());
            response.header.set_checksum();

            self.send_message_to_replica(message.header.replica, response);
        }

        fn on_nack_prepare(self: *Self, message: *Message) void {
            if (self.ignore_repair_message(message)) return;

            assert(self.status == .view_change);
            assert(message.header.view == self.view);
            assert(message.header.replica != self.replica);
            assert(self.primary_index(self.view) == self.replica);
            assert(self.do_view_change_quorum);
            assert(self.repairs_allowed());

            if (self.nack_prepare_op == null) {
                log.debug("{}: on_nack_prepare: ignoring (no longer expected)", .{self.replica});
                return;
            }

            const op = self.nack_prepare_op.?;
            const checksum = self.journal.header_with_op(op).?.checksum;
            const slot = self.journal.slot_with_op(op).?;

            if (message.header.op != op) {
                log.debug("{}: on_nack_prepare: ignoring (repairing another op)", .{self.replica});
                return;
            }

            if (message.header.context != checksum) {
                log.debug("{}: on_nack_prepare: ignoring (repairing another checksum)", .{
                    self.replica,
                });
                return;
            }

            // backups may not send a `nack_prepare` for a different checksum:
            // However our op may change in between sending the request and getting the nack.
            assert(message.header.op == op);
            assert(message.header.context == checksum);

            // Here are what our nack quorums look like, if we know our op is faulty:
            // These are for various replication quorums under Flexible Paxos.
            // We need to have enough nacks to guarantee that `quorum_replication` was not reached,
            // because if the replication quorum was reached, then it may have been committed.
            // We add `1` in each case because our op is faulty and may have been counted.
            //
            // replica_count=2 - quorum_replication=2 + 1 = 0 + 1 = 1 nacks required
            // replica_count=3 - quorum_replication=2 + 1 = 1 + 1 = 2 nacks required
            // replica_count=4 - quorum_replication=2 + 1 = 2 + 1 = 3 nacks required
            // replica_count=4 - quorum_replication=3 + 1 = 1 + 1 = 2 nacks required
            // replica_count=5 - quorum_replication=2 + 1 = 3 + 1 = 4 nacks required
            // replica_count=5 - quorum_replication=3 + 1 = 2 + 1 = 3 nacks required
            //
            // Otherwise, if we know we do not have the op, then we can exclude ourselves.
            assert(self.replica_count > 1);

            const threshold = if (self.journal.faulty.bit(slot))
                self.replica_count - self.quorum_replication + 1
            else
                self.replica_count - self.quorum_replication;

            if (threshold == 0) {
                assert(self.replica_count == 2);
                assert(!self.journal.faulty.bit(slot));

                // This is a special case for a cluster-of-two, handled in `repair_prepare()`.
                log.debug("{}: on_nack_prepare: ignoring (cluster-of-two, not faulty)", .{
                    self.replica,
                });
                return;
            }

            log.debug("{}: on_nack_prepare: quorum_replication={} threshold={} op={}", .{
                self.replica,
                self.quorum_replication,
                threshold,
                op,
            });

            // We should never expect to receive a nack from ourselves:
            // Detect if we ever set `threshold` to `quorum_view_change` for a cluster-of-two again.
            assert(threshold < self.replica_count);

            // Wait until we have `threshold` messages for quorum:
            const count = self.count_message_and_receive_quorum_exactly_once(
                &self.nack_prepare_from_other_replicas,
                message,
                threshold,
            ) orelse return;

            assert(count == threshold);
            assert(!self.nack_prepare_from_other_replicas.isSet(self.replica));
            log.debug("{}: on_nack_prepare: quorum received op={}", .{ self.replica, op });

            self.primary_discard_uncommitted_ops_from(op, checksum);
            self.reset_quorum_nack_prepare();
            self.repair();
        }

        fn on_headers(self: *Self, message: *const Message) void {
            if (self.ignore_repair_message(message)) return;

            assert(self.status == .normal or self.status == .view_change);
            assert(message.header.view == self.view);
            assert(message.header.replica != self.replica);

            // We expect at least one header in the body, or otherwise no response to our request.
            assert(message.header.size > @sizeOf(Header));

            var op_min: ?u64 = null;
            var op_max: ?u64 = null;
            for (message_body_as_headers(message)) |*h| {
                if (op_min == null or h.op < op_min.?) op_min = h.op;
                if (op_max == null or h.op > op_max.?) op_max = h.op;
                _ = self.repair_header(h);
            }
            assert(op_max.? >= op_min.?);

            self.repair();
        }

        fn on_ping_timeout(self: *Self) void {
            self.ping_timeout.reset();

            // TODO We may want to ping for connectivity during a view change.
            assert(self.status == .normal);
            assert(self.primary() or self.backup());

            var ping = Header{
                .command = .ping,
                .cluster = self.cluster,
                .replica = self.replica,
                .view = self.view,
                .op = self.clock.monotonic(),
            };

            self.send_header_to_other_replicas(ping);
        }

        fn on_prepare_timeout(self: *Self) void {
            // We will decide below whether to reset or backoff the timeout.
            assert(self.status == .normal);
            assert(self.primary());

            const prepare = self.pipeline.head_ptr().?;
            assert(prepare.message.header.command == .prepare);

            if (prepare.ok_quorum_received) {
                self.prepare_timeout.reset();

                // We were unable to commit at the time because we were waiting for a message.
                log.debug("{}: on_prepare_timeout: quorum already received, retrying commit", .{
                    self.replica,
                });
                self.commit_pipeline();
                return;
            }

            // The list of remote replicas yet to send a prepare_ok:
            var waiting: [constants.replicas_max]u8 = undefined;
            var waiting_len: usize = 0;
            var ok_from_all_replicas_iterator = prepare.ok_from_all_replicas.iterator(.{
                .kind = .unset,
            });
            while (ok_from_all_replicas_iterator.next()) |replica| {
                // Ensure we don't wait for replicas that don't exist.
                // The bits between `replica_count` and `replicas_max` are always unset,
                // since they don't actually represent replicas.
                if (replica == self.replica_count) {
                    assert(self.replica_count < constants.replicas_max);
                    break;
                }
                assert(replica < self.replica_count);

                if (replica != self.replica) {
                    waiting[waiting_len] = @intCast(u8, replica);
                    waiting_len += 1;
                }
            } else {
                assert(self.replica_count == constants.replicas_max);
            }

            if (waiting_len == 0) {
                self.prepare_timeout.reset();

                log.debug("{}: on_prepare_timeout: waiting for journal", .{self.replica});
                assert(!prepare.ok_from_all_replicas.isSet(self.replica));

                // We may be slow and waiting for the write to complete.
                //
                // We may even have maxed out our IO depth and been unable to initiate the write,
                // which can happen if `constants.pipeline_max` exceeds `constants.journal_iops_write_max`.
                // This can lead to deadlock for a cluster of one or two (if we do not retry here),
                // since there is no other way for the primary to repair the dirty op because no
                // other replica has it.
                //
                // Retry the write through `on_repair()` which will work out which is which.
                // We do expect that the op would have been run through `on_prepare()` already.
                assert(prepare.message.header.op <= self.op);
                self.on_repair(prepare.message);

                return;
            }

            self.prepare_timeout.backoff(self.prng.random());

            assert(waiting_len <= self.replica_count);
            for (waiting[0..waiting_len]) |replica| {
                assert(replica < self.replica_count);

                log.debug("{}: on_prepare_timeout: waiting for replica {}", .{
                    self.replica,
                    replica,
                });
            }

            // Cycle through the list to reach live replicas and get around partitions:
            // We do not assert `prepare_timeout.attempts > 0` since the counter may wrap back to 0.
            const replica = waiting[self.prepare_timeout.attempts % waiting_len];
            assert(replica != self.replica);

            log.debug("{}: on_prepare_timeout: replicating to replica {}", .{
                self.replica,
                replica,
            });
            self.send_message_to_replica(replica, prepare.message);
        }

        fn on_commit_timeout(self: *Self) void {
            self.commit_timeout.reset();

            assert(self.status == .normal);
            assert(self.primary());
            assert(self.commit_min == self.commit_max);

            // TODO Snapshots: Use snapshot checksum if commit is no longer in journal.
            const latest_committed_entry = self.journal.header_with_op(self.commit_max).?;

            self.send_header_to_other_replicas(.{
                .command = .commit,
                .context = latest_committed_entry.checksum,
                .cluster = self.cluster,
                .replica = self.replica,
                .view = self.view,
                .commit = self.commit_max,
            });
        }

        fn on_normal_status_timeout(self: *Self) void {
            assert(self.status == .normal);
            assert(self.backup());
            self.transition_to_view_change_status(self.view + 1);
        }

        fn on_view_change_status_timeout(self: *Self) void {
            assert(self.status == .view_change);
            self.transition_to_view_change_status(self.view + 1);
        }

        fn on_view_change_message_timeout(self: *Self) void {
            self.view_change_message_timeout.reset();
            assert(self.status == .view_change);

            // Keep sending `start_view_change` messages:
            // We may have a `start_view_change_quorum` but other replicas may not.
            // However, the primary may stop sending once it has a `do_view_change_quorum`.
            if (!self.do_view_change_quorum) self.send_start_view_change();

            // It is critical that a `do_view_change` message implies a `start_view_change_quorum`:
            if (self.start_view_change_quorum) {
                // The primary need not retry to send a `do_view_change` message to itself:
                // We assume the MessageBus will not drop messages sent by a replica to itself.
                if (self.primary_index(self.view) != self.replica) self.send_do_view_change();
            }
        }

        fn on_repair_timeout(self: *Self) void {
            assert(self.status == .normal or self.status == .view_change);
            self.repair();
        }

        fn on_recovery_timeout(self: *Self) void {
            assert(self.status == .recovering);
            assert(self.replica_count > 1);
            self.recovery_timeout.reset();
            self.recover();
        }

        fn reference_message_and_receive_quorum_exactly_once(
            self: *Self,
            messages: *QuorumMessages,
            message: *Message,
            threshold: u32,
        ) ?usize {
            assert(threshold >= 1);
            assert(threshold <= self.replica_count);

            assert(messages.len == constants.replicas_max);
            assert(message.header.cluster == self.cluster);
            assert(message.header.replica < self.replica_count);
            assert(message.header.view == self.view);
            switch (message.header.command) {
                .do_view_change => {
                    assert(self.replica_count > 1);
                    if (self.replica_count == 2) assert(threshold == 2);

                    assert(self.status == .view_change);
                    assert(self.primary_index(self.view) == self.replica);
                },
                else => unreachable,
            }

            const command: []const u8 = @tagName(message.header.command);

            // Do not allow duplicate messages to trigger multiple passes through a state transition:
            if (messages[message.header.replica]) |m| {
                // Assert that this is a duplicate message and not a different message:
                assert(m.header.command == message.header.command);
                assert(m.header.replica == message.header.replica);
                assert(m.header.view == message.header.view);
                assert(m.header.op == message.header.op);
                assert(m.header.checksum_body == message.header.checksum_body);

                if (message.header.command == .do_view_change) {
                    // Replicas don't resend `do_view_change` messages to themselves.
                    assert(message.header.replica != self.replica);
                    // A replica may resend a `do_view_change` with a different commit if it was
                    // committing originally. Keep the one with the highest commit.
                    // This is *not* necessary for correctness.
                    if (m.header.commit < message.header.commit) {
                        log.debug("{}: on_{s}: replacing (newer message replica={} commit={}..{})", .{
                            self.replica,
                            command,
                            message.header.replica,
                            m.header.commit,
                            message.header.commit,
                        });
                        // TODO(Buggify): skip updating the DVC, since it isn't required for correctness.
                        self.message_bus.unref(m);
                        messages[message.header.replica] = message.ref();
                    } else if (m.header.commit > message.header.commit) {
                        log.debug("{}: on_{s}: ignoring (older message replica={})", .{
                            self.replica,
                            command,
                            message.header.replica,
                        });
                    } else {
                        assert(m.header.checksum == message.header.checksum);
                    }
                } else {
                    assert(m.header.commit == message.header.commit);
                    assert(m.header.checksum == message.header.checksum);
                }

                log.debug("{}: on_{s}: ignoring (duplicate message replica={})", .{
                    self.replica,
                    command,
                    message.header.replica,
                });
                return null;
            }

            // Record the first receipt of this message:
            assert(messages[message.header.replica] == null);
            messages[message.header.replica] = message.ref();

            // Count the number of unique messages now received:
            const count = self.count_quorum(messages, message.header.command, message.header.context);
            log.debug("{}: on_{s}: {} message(s)", .{ self.replica, command, count });

            // Wait until we have exactly `threshold` messages for quorum:
            if (count < threshold) {
                log.debug("{}: on_{s}: waiting for quorum", .{ self.replica, command });
                return null;
            }

            // This is not the first time we have had quorum, the state transition has already happened:
            if (count > threshold) {
                log.debug("{}: on_{s}: ignoring (quorum received already)", .{
                    self.replica,
                    command,
                });
                return null;
            }

            assert(count == threshold);
            return count;
        }

        fn count_message_and_receive_quorum_exactly_once(
            self: *Self,
            counter: *QuorumCounter,
            message: *Message,
            threshold: u32,
        ) ?usize {
            assert(threshold >= 1);
            assert(threshold <= self.replica_count);

            assert(QuorumCounter.bit_length == constants.replicas_max);
            assert(message.header.cluster == self.cluster);
            assert(message.header.replica < self.replica_count);
            assert(message.header.view == self.view);

            switch (message.header.command) {
                .prepare_ok => {
                    if (self.replica_count <= 2) assert(threshold == self.replica_count);

                    assert(self.status == .normal);
                    assert(self.primary());
                },
                .start_view_change => {
                    assert(self.replica_count > 1);
                    if (self.replica_count == 2) assert(threshold == 1);

                    assert(self.status == .view_change);
                    assert(self.replica != message.header.replica);
                },
                .nack_prepare => {
                    assert(self.replica_count > 1);
                    if (self.replica_count == 2) assert(threshold >= 1);

                    assert(self.status == .view_change);
                    assert(self.primary_index(self.view) == self.replica);
                    assert(message.header.replica != self.replica);
                    assert(message.header.op == self.nack_prepare_op.?);
                },
                else => unreachable,
            }

            const command: []const u8 = @tagName(message.header.command);

            // Do not allow duplicate messages to trigger multiple passes through a state transition:
            if (counter.isSet(message.header.replica)) {
                log.debug("{}: on_{s}: ignoring (duplicate message replica={})", .{
                    self.replica,
                    command,
                    message.header.replica,
                });
                return null;
            }

            // Record the first receipt of this message:
            counter.set(message.header.replica);
            assert(counter.isSet(message.header.replica));

            // Count the number of unique messages now received:
            const count = counter.count();
            log.debug("{}: on_{s}: {} message(s)", .{ self.replica, command, count });
            assert(count <= self.replica_count);

            // Wait until we have exactly `threshold` messages for quorum:
            if (count < threshold) {
                log.debug("{}: on_{s}: waiting for quorum", .{ self.replica, command });
                return null;
            }

            // This is not the first time we have had quorum, the state transition has already happened:
            if (count > threshold) {
                log.debug("{}: on_{s}: ignoring (quorum received already)", .{
                    self.replica,
                    command,
                });
                return null;
            }

            assert(count == threshold);
            return count;
        }

        fn append(self: *Self, message: *Message) void {
            assert(self.status == .normal);
            assert(message.header.command == .prepare);
            assert(message.header.view == self.view);
            assert(message.header.op == self.op);

            if (self.replica_count == 1 and self.pipeline.count > 1) {
                // In a cluster-of-one, the prepares must always be written to the WAL sequentially
                // (never concurrently). This ensures that there will be no gaps in the WAL during
                // crash recovery.
                log.debug("{}: append: serializing append op={}", .{
                    self.replica,
                    message.header.op,
                });
            } else {
                log.debug("{}: append: appending to journal op={}", .{
                    self.replica,
                    message.header.op,
                });
                self.write_prepare(message, .append);
            }
        }

        /// Returns whether `b` succeeds `a` by having a newer view or same view and newer op.
        fn ascending_viewstamps(
            a: *const Header,
            b: *const Header,
        ) bool {
            assert(a.command == .prepare);
            assert(b.command == .prepare);

            if (a.view < b.view) {
                // We do not assert b.op >= a.op, ops may be reordered during a view change.
                return true;
            } else if (a.view > b.view) {
                // We do not assert b.op <= a.op, ops may be reordered during a view change.
                return false;
            } else if (a.op < b.op) {
                assert(a.view == b.view);
                return true;
            } else if (a.op > b.op) {
                assert(a.view == b.view);
                return false;
            } else {
                unreachable;
            }
        }

        /// Choose a different replica each time if possible (excluding ourself).
        fn choose_any_other_replica(self: *Self) ?u8 {
            if (self.replica_count == 1) return null;

            var count: usize = 0;
            while (count < self.replica_count) : (count += 1) {
                self.choose_any_other_replica_ticks += 1;
                const replica = @mod(
                    self.replica + self.choose_any_other_replica_ticks,
                    self.replica_count,
                );
                if (replica == self.replica) continue;
                return @intCast(u8, replica);
            }
            unreachable;
        }

        /// Commit ops up to commit number `commit` (inclusive).
        /// A function which calls `commit_journal()` to set `commit_max` must first call
        /// `view_jump()`. Otherwise, we may fork the log.
        fn commit_journal(self: *Self, commit: u64) void {
            // TODO Restrict `view_change` status only to the primary purely as defense-in-depth.
            // Be careful of concurrency when doing this, as successive view changes can happen quickly.
            assert(self.status == .normal or self.status == .view_change or
                (self.status == .recovering and self.replica_count == 1));
            assert(self.commit_min <= self.commit_max);
            assert(self.commit_min <= self.op);
            assert(self.commit_max <= self.op or self.commit_max > self.op);
            assert(commit <= self.op or commit > self.op);

            // We have already committed this far:
            if (commit <= self.commit_min) return;

            // We must update `commit_max` even if we are already committing, otherwise we will lose
            // information that we should know, and `set_op_and_commit_max()` will catch us out:
            if (commit > self.commit_max) {
                log.debug("{}: commit_journal: advancing commit_max={}..{}", .{
                    self.replica,
                    self.commit_max,
                    commit,
                });
                self.commit_max = commit;
            }

            // Guard against multiple concurrent invocations of commit_journal()/commit_pipeline():
            if (self.committing) {
                log.debug("{}: commit_journal: already committing...", .{self.replica});
                return;
            }

            // We check the hash chain before we read each op, rather than once upfront, because
            // it's possible for `commit_max` to change while we read asynchronously, after we
            // validate the hash chain.
            //
            // We therefore cannot keep committing until we reach `commit_max`. We need to verify
            // the hash chain before each read. Once verified (before the read) we can commit in the
            // callback after the read, but if we see a change we need to stop committing any
            // further ops, because `commit_max` may have been bumped and may refer to a different
            // op.

            assert(!self.committing);
            self.committing = true;

            self.commit_journal_next();
        }

        fn commit_journal_next(self: *Self) void {
            assert(self.committing);
            assert(self.status == .normal or self.status == .view_change or
                (self.status == .recovering and self.replica_count == 1));
            assert(self.commit_min <= self.commit_max);
            assert(self.commit_min <= self.op);

            if (!self.valid_hash_chain("commit_journal_next")) {
                assert(self.replica_count > 1);
                self.commit_ops_done();
                return;
            }
            assert(self.op >= self.commit_max);

            // We may receive commit numbers for ops we do not yet have (`commit_max > self.op`):
            // Even a naive state transfer may fail to correct for this.
            if (self.commit_min < self.commit_max and self.commit_min < self.op) {
                const op = self.commit_min + 1;
                const checksum = self.journal.header_with_op(op).?.checksum;
                self.journal.read_prepare(commit_journal_next_callback, op, checksum, null);
            } else {
                self.commit_ops_done();
                // This is an optimization to expedite the view change before the `repair_timeout`:
                if (self.status == .view_change and self.repairs_allowed()) self.repair();

                if (self.status == .recovering) {
                    assert(self.replica_count == 1);
                    assert(self.commit_min == self.commit_max);
                    assert(self.commit_min == self.op);
                    self.transition_to_normal_from_recovering_status(0);
                } else {
                    // We expect that a cluster-of-one only calls commit_journal() in recovering status.
                    assert(self.replica_count > 1);
                }
            }
        }

        fn commit_journal_next_callback(self: *Self, prepare: ?*Message, destination_replica: ?u8) void {
            assert(self.committing);
            assert(destination_replica == null);

            if (prepare == null) {
                self.commit_ops_done();
                log.debug("{}: commit_journal_next_callback: prepare == null", .{self.replica});
                if (self.replica_count == 1) @panic("cannot recover corrupt prepare");
                return;
            }

            const slot = self.journal.slot_with_op_and_checksum(
                prepare.?.header.op,
                prepare.?.header.checksum,
            ).?;
            assert(self.journal.prepare_inhabited[slot.index]);
            assert(self.journal.prepare_checksums[slot.index] == prepare.?.header.checksum);
            assert(self.journal.has(prepare.?.header));

            switch (self.status) {
                .normal => {},
                .view_change => {
                    if (self.primary_index(self.view) != self.replica) {
                        self.commit_ops_done();
                        log.debug("{}: commit_journal_next_callback: no longer primary view={}", .{
                            self.replica,
                            self.view,
                        });
                        assert(self.replica_count > 1);
                        return;
                    }
                    // Only the primary may commit during a view change before starting the new view.
                    // Fall through if this is indeed the case.
                },
                .recovering => {
                    assert(self.replica_count == 1);
                    assert(self.primary_index(self.view) == self.replica);
                },
            }

            const op = self.commit_min + 1;
            assert(prepare.?.header.op == op);

            self.commit_op_prefetch(prepare.?, commit_journal_callback);
        }

        fn commit_journal_callback(self: *Self) void {
            assert(self.committing);
            assert(self.commit_min <= self.commit_max);
            assert(self.commit_min <= self.op);

            self.commit_journal_next();
        }

        /// Begin the commit path that is common between `commit_pipeline` and `commit_journal`:
        ///
        /// 1. prefetch
        /// 2. commit_op: Update the state machine and the replica's commit_min/commit_max.
        /// 3. compact
        /// 4. checkpoint: (Only called when `commit_min == op_checkpoint_trigger`).
        /// 5. done: Call the `callback` that was passed to `commit_op_prefetch`.
        fn commit_op_prefetch(
            self: *Self,
            prepare: *Message,
            callback: fn (*Self) void,
        ) void {
            assert(self.committing);
            assert(self.status == .normal or self.status == .view_change or
                (self.status == .recovering and self.replica_count == 1));
            assert(self.commit_prepare == null);
            assert(self.commit_callback == null);
            assert(prepare.header.command == .prepare);
            assert(prepare.header.operation != .root);
            assert(prepare.header.op == self.commit_min + 1);
            assert(prepare.header.op <= self.op);

            tracer.start(
                &self.tracer_slot_commit,
                .main,
                .{ .commit = .{ .op = prepare.header.op } },
                @src(),
            );

            self.commit_prepare = prepare.ref();
            self.commit_callback = callback;
            self.state_machine.prefetch(
                commit_op_prefetch_callback,
                prepare.header.op,
                prepare.header.operation.cast(StateMachine),
                prepare.body(),
            );
        }

        fn commit_op_prefetch_callback(state_machine: *StateMachine) void {
            const self = @fieldParentPtr(Self, "state_machine", state_machine);
            assert(self.committing);
            assert(self.commit_prepare != null);
            assert(self.commit_callback != null);
            assert(self.commit_prepare.?.header.op == self.commit_min + 1);

            self.commit_op(self.commit_prepare.?);
            assert(self.commit_min == self.commit_prepare.?.header.op);
            assert(self.commit_min <= self.commit_max);

            if (self.status == .normal and self.primary()) {
                const prepare = self.pipeline.pop().?;
                assert(self.commit_min == self.commit_max);
                assert(prepare.message.header.checksum == self.commit_prepare.?.header.checksum);
                assert(prepare.message.header.op == self.commit_min);
                assert(prepare.message.header.op == self.commit_max);
                assert(self.prepare_timeout.ticking);

                self.message_bus.unref(prepare.message);

                if (self.pipeline.head_ptr()) |next| {
                    assert(next.message.header.op == self.commit_min + 1);
                    assert(next.message.header.op == self.commit_prepare.?.header.op + 1);

                    if (self.replica_count == 1) {
                        // Write the next message in the queue.
                        // A cluster-of-one writes prepares sequentially to avoid gaps in the
                        // WAL caused by reordered writes.
                        log.debug("{}: append: appending to journal op={}", .{
                            self.replica,
                            next.message.header.op,
                        });
                        self.write_prepare(next.message, .append);
                    }
                } else {
                    // When the pipeline is empty, stop the prepare timeout.
                    // The timeout will be restarted when another entry arrives for the pipeline.
                    self.prepare_timeout.stop();
                }
            }

            self.state_machine.compact(commit_op_compact_callback, self.commit_prepare.?.header.op);
        }

        fn commit_op_compact_callback(state_machine: *StateMachine) void {
            const self = @fieldParentPtr(Self, "state_machine", state_machine);
            assert(self.committing);
            assert(self.commit_callback != null);
            assert(self.op_checkpoint == self.superblock.staging.vsr_state.commit_min);
            assert(self.op_checkpoint == self.superblock.working.vsr_state.commit_min);

            const op = self.commit_prepare.?.header.op;
            assert(op == self.commit_min);
            assert(op <= self.op_checkpoint_trigger());

            if (self.on_compact) |on_compact| on_compact(self);

            if (op == self.op_checkpoint_trigger()) {
                assert(op == self.op);
                assert((op + 1) % constants.lsm_batch_multiple == 0);
                log.debug("{}: commit_op_compact_callback: checkpoint start " ++
                    "(op={} current_checkpoint={} next_checkpoint={})", .{
                    self.replica,
                    self.op,
                    self.op_checkpoint,
                    self.op_checkpoint_next(),
                });
                tracer.start(
                    &self.tracer_slot_checkpoint,
                    .main,
                    .checkpoint,
                    @src(),
                );
                self.state_machine.checkpoint(commit_op_checkpoint_state_machine_callback);
            } else {
                self.commit_op_done();
            }
        }

        fn commit_op_checkpoint_state_machine_callback(state_machine: *StateMachine) void {
            const self = @fieldParentPtr(Self, "state_machine", state_machine);
            assert(self.committing);
            assert(self.commit_callback != null);
            assert(self.commit_prepare.?.header.op == self.op);
            assert(self.commit_prepare.?.header.op == self.commit_min);
            assert(self.commit_prepare.?.header.op == self.op_checkpoint_trigger());

            // For the given WAL (journal_slot_count=8, lsm_batch_multiple=2, op=commit_min=7):
            //
            //   A  B  C  D  E
            //   |01|23|45|67|
            //
            // The checkpoint is triggered at "E".
            // At this point, ops 6 and 7 are in the in-memory immutable table.
            // They will only be compacted to disk in the next bar.
            // Therefore, only ops "A..D" are committed to disk.
            // Thus, the SuperBlock's `commit_min` is set to 7-2=5.
            const vsr_state_commit_min = self.op_checkpoint_next();
            const vsr_state_new = .{
                .commit_min_checksum = self.journal.header_with_op(vsr_state_commit_min).?.checksum,
                .commit_min = vsr_state_commit_min,
                .commit_max = self.commit_max,
                .view_normal = self.view_normal,
                .view = self.view,
            };
            assert(self.superblock.working.vsr_state.monotonic(vsr_state_new));

            self.superblock.checkpoint(
                commit_op_checkpoint_superblock_callback,
                &self.superblock_context,
                vsr_state_new,
            );
        }

        fn commit_op_checkpoint_superblock_callback(superblock_context: *SuperBlock.Context) void {
            const self = @fieldParentPtr(Self, "superblock_context", superblock_context);
            assert(self.committing);
            assert(self.commit_callback != null);
            assert(self.commit_prepare.?.header.op == self.op);
            assert(self.commit_prepare.?.header.op == self.commit_min);

            self.op_checkpoint = self.op_checkpoint_next();
            assert(self.op_checkpoint == self.commit_min - constants.lsm_batch_multiple);
            assert(self.op_checkpoint == self.superblock.staging.vsr_state.commit_min);
            assert(self.op_checkpoint == self.superblock.working.vsr_state.commit_min);

            log.debug("{}: commit_op_compact_callback: checkpoint done (op={} new_checkpoint={})", .{
                self.replica,
                self.op,
                self.op_checkpoint,
            });
            tracer.end(
                &self.tracer_slot_checkpoint,
                .main,
                .checkpoint,
            );

            if (self.on_checkpoint) |on_checkpoint| on_checkpoint(self);
            self.commit_op_done();
        }

        fn commit_op_done(self: *Self) void {
            const callback = self.commit_callback.?;
            assert(self.committing);
            assert(self.commit_prepare.?.header.op == self.commit_min);
            assert(self.commit_prepare.?.header.op < self.op_checkpoint_trigger());

            const op = self.commit_prepare.?.header.op;

            self.message_bus.unref(self.commit_prepare.?);
            self.commit_prepare = null;
            self.commit_callback = null;

            tracer.end(
                &self.tracer_slot_commit,
                .main,
                .{ .commit = .{ .op = op } },
            );

            callback(self);
        }

        fn commit_op(self: *Self, prepare: *const Message) void {
            // TODO Can we add more checks around allowing commit_op() during a view change?
            assert(self.committing);
            assert(self.commit_prepare.? == prepare);
            assert(self.commit_callback != null);
            assert(self.status == .normal or self.status == .view_change or
                (self.status == .recovering and self.replica_count == 1));
            assert(prepare.header.command == .prepare);
            assert(prepare.header.operation != .root);
            assert(prepare.header.op == self.commit_min + 1);
            assert(prepare.header.op <= self.op);

            // If we are a backup committing through `commit_journal()` then a view change may
            // have happened since we last checked in `commit_journal_next()`. However, this would
            // relate to subsequent ops, since by now we have already verified the hash chain for
            // this commit.

            assert(self.journal.has(prepare.header));
            if (self.op_checkpoint == self.commit_min) {
                // op_checkpoint's slot may have been overwritten in the WAL — but we can
                // always use the VSRState to anchor the hash chain.
                assert(prepare.header.parent ==
                    self.superblock.working.vsr_state.commit_min_checksum);
            } else {
                assert(prepare.header.parent ==
                    self.journal.header_with_op(self.commit_min).?.checksum);
            }

            log.debug("{}: commit_op: executing view={} primary={} op={} checksum={} ({s})", .{
                self.replica,
                self.view,
                self.primary_index(self.view) == self.replica,
                prepare.header.op,
                prepare.header.checksum,
                @tagName(prepare.header.operation.cast(StateMachine)),
            });

            const reply = self.message_bus.get_message();
            defer self.message_bus.unref(reply);

            log.debug("{}: commit_op: commit_timestamp={} prepare.header.timestamp={}", .{
                self.replica,
                self.state_machine.commit_timestamp,
                prepare.header.timestamp,
            });
            assert(self.state_machine.commit_timestamp < prepare.header.timestamp);

            const reply_body_size = @intCast(u32, self.state_machine.commit(
                prepare.header.client,
                prepare.header.op,
                prepare.header.operation.cast(StateMachine),
                prepare.buffer[@sizeOf(Header)..prepare.header.size],
                reply.buffer[@sizeOf(Header)..],
            ));

            assert(self.state_machine.commit_timestamp <= prepare.header.timestamp);
            self.state_machine.commit_timestamp = prepare.header.timestamp;

            self.commit_min += 1;
            assert(self.commit_min == prepare.header.op);
            if (self.commit_min > self.commit_max) self.commit_max = self.commit_min;

            if (self.on_change_state) |hook| hook(self);

            reply.header.* = .{
                .command = .reply,
                .operation = prepare.header.operation,
                .parent = prepare.header.context, // The prepare's context has `request.checksum`.
                .client = prepare.header.client,
                .request = prepare.header.request,
                .cluster = prepare.header.cluster,
                .replica = prepare.header.replica,
                .view = prepare.header.view,
                .op = prepare.header.op,
                .timestamp = prepare.header.timestamp,
                .commit = prepare.header.op,
                .size = @sizeOf(Header) + reply_body_size,
            };
            assert(reply.header.epoch == 0);

            reply.header.set_checksum_body(reply.body());
            reply.header.set_checksum();

            if (self.superblock.working.vsr_state.op_compacted(prepare.header.op)) {
                // We are recovering from a checkpoint. Prior to the crash, the client table was
                // updated with entries for one bar beyond the op_checkpoint.
                assert(self.op_checkpoint == self.superblock.working.vsr_state.commit_min);
                if (self.client_table().get(prepare.header.client)) |entry| {
                    assert(entry.reply.header.command == .reply);
                    assert(entry.reply.header.op >= prepare.header.op);
                } else {
                    assert(self.client_table().count() == self.client_table().capacity());
                }

                log.debug("{}: commit_op: skip client table update: prepare.op={} checkpoint={}", .{
                    self.replica,
                    prepare.header.op,
                    self.op_checkpoint,
                });
            } else {
                if (reply.header.operation == .register) {
                    self.create_client_table_entry(reply);
                } else {
                    self.update_client_table_entry(reply);
                }
            }

            if (self.primary_index(self.view) == self.replica) {
                log.debug("{}: commit_op: replying to client: {}", .{ self.replica, reply.header });
                self.message_bus.send_message_to_client(reply.header.client, reply);
            }
        }

        /// Commits, frees and pops as many prepares at the head of the pipeline as have quorum.
        /// Can be called only when the replica is the primary.
        /// Can be called only when the pipeline has at least one prepare.
        fn commit_pipeline(self: *Self) void {
            assert(self.status == .normal);
            assert(self.primary());
            assert(self.pipeline.count > 0);

            // Guard against multiple concurrent invocations of commit_journal()/commit_pipeline():
            if (self.committing) {
                log.debug("{}: commit_pipeline: already committing...", .{self.replica});
                return;
            }

            self.committing = true;
            self.commit_pipeline_next();
        }

        fn commit_pipeline_next(self: *Self) void {
            assert(self.committing);
            assert(self.status == .normal);
            assert(self.primary());

            if (self.pipeline.head_ptr()) |prepare| {
                assert(self.commit_min == self.commit_max);
                assert(self.commit_min + 1 == prepare.message.header.op);
                assert(self.commit_min + self.pipeline.count == self.op);
                assert(self.journal.has(prepare.message.header));

                if (!prepare.ok_quorum_received) {
                    // Eventually handled by on_prepare_timeout().
                    log.debug("{}: commit_pipeline: waiting for quorum", .{self.replica});
                    self.commit_ops_done();
                    return;
                }

                const count = prepare.ok_from_all_replicas.count();
                assert(count >= self.quorum_replication);
                assert(count <= self.replica_count);

                self.commit_op_prefetch(prepare.message, commit_pipeline_callback);
            } else {
                self.commit_ops_done();
            }
        }

        fn commit_pipeline_callback(self: *Self) void {
            assert(self.committing);
            assert(self.commit_min <= self.commit_max);
            assert(self.commit_min <= self.op);

            if (self.status == .normal and self.primary()) {
                if (self.pipeline.head_ptr()) |pipeline_head| {
                    assert(pipeline_head.message.header.op == self.commit_min + 1);
                }
                self.commit_pipeline_next();
            } else {
                self.commit_ops_done();
            }
        }

        fn commit_ops_done(self: *Self) void {
            assert(self.committing);
            self.committing = false;
        }

        fn copy_latest_headers_and_set_size(
            self: *const Self,
            op_min: u64,
            op_max: u64,
            count_max: ?usize,
            message: *Message,
        ) usize {
            assert(op_max >= op_min);
            assert(count_max == null or count_max.? > 0);
            assert(message.header.command == .do_view_change or
                message.header.command == .start_view or
                message.header.command == .headers or
                message.header.command == .recovery_response);

            const body_size_max = @sizeOf(Header) * std.math.min(
                @divExact(message.buffer.len - @sizeOf(Header), @sizeOf(Header)),
                // We must add 1 because op_max and op_min are both inclusive:
                count_max orelse std.math.min(64, op_max - op_min + 1),
            );
            assert(body_size_max >= @sizeOf(Header));
            assert(count_max == null or body_size_max == count_max.? * @sizeOf(Header));

            const count = self.journal.copy_latest_headers_between(
                op_min,
                op_max,
                std.mem.bytesAsSlice(
                    Header,
                    message.buffer[@sizeOf(Header)..][0..body_size_max],
                ),
            );

            message.header.size = @intCast(u32, @sizeOf(Header) * (1 + count));

            return count;
        }

        fn count_quorum(
            self: *Self,
            messages: *QuorumMessages,
            command: Command,
            context: u128,
        ) usize {
            assert(messages.len == constants.replicas_max);
            var count: usize = 0;
            for (messages) |received, replica| {
                if (received) |m| {
                    assert(replica < self.replica_count);
                    assert(m.header.cluster == self.cluster);
                    assert(m.header.command == command);
                    assert(m.header.context == context);
                    assert(m.header.replica == replica);
                    switch (command) {
                        .do_view_change => assert(m.header.view == self.view),
                        .recovery_response => assert(m.header.replica != self.replica),
                        else => unreachable,
                    }
                    count += 1;
                }
            }
            assert(count <= self.replica_count);
            return count;
        }

        /// Creates an entry in the client table when registering a new client session.
        /// Asserts that the new session does not yet exist.
        /// Evicts another entry deterministically, if necessary, to make space for the insert.
        fn create_client_table_entry(self: *Self, reply: *Message) void {
            assert(reply.header.command == .reply);
            assert(reply.header.operation == .register);
            assert(reply.header.client > 0);
            assert(reply.header.context == 0);
            assert(reply.header.op == reply.header.commit);
            assert(reply.header.size == @sizeOf(Header));

            const session = reply.header.commit; // The commit number becomes the session number.
            const request = reply.header.request;

            // We reserved the `0` commit number for the cluster `.root` operation.
            assert(session > 0);
            assert(request == 0);

            // For correctness, it's critical that all replicas evict deterministically:
            // We cannot depend on `HashMap.capacity()` since `HashMap.ensureTotalCapacity()` may
            // change across versions of the Zig std lib. We therefore rely on
            // `constants.clients_max`, which must be the same across all replicas, and must not
            // change after initializing a cluster.
            // We also do not depend on `HashMap.valueIterator()` being deterministic here. However,
            // we do require that all entries have different commit numbers and are iterated.
            // This ensures that we will always pick the entry with the oldest commit number.
            // We also check that a client has only one entry in the hash map (or it's buggy).
            const clients = self.client_table().count();
            assert(clients <= constants.clients_max);
            if (clients == constants.clients_max) {
                var evictee: ?*Message = null;
                var iterated: usize = 0;
                var iterator = self.client_table().iterator();
                while (iterator.next()) |entry| : (iterated += 1) {
                    assert(entry.reply.header.command == .reply);
                    assert(entry.reply.header.context == 0);
                    assert(entry.reply.header.op == entry.reply.header.commit);
                    assert(entry.reply.header.commit >= entry.session);

                    if (evictee) |evictee_reply| {
                        assert(entry.reply.header.client != evictee_reply.header.client);
                        assert(entry.reply.header.commit != evictee_reply.header.commit);

                        if (entry.reply.header.commit < evictee_reply.header.commit) {
                            evictee = entry.reply;
                        }
                    } else {
                        evictee = entry.reply;
                    }
                }
                assert(iterated == clients);
                log.err("{}: create_client_table_entry: clients={}/{} evicting client={}", .{
                    self.replica,
                    clients,
                    constants.clients_max,
                    evictee.?.header.client,
                });
                self.client_table().remove(evictee.?.header.client);
                self.message_bus.unref(evictee.?);
            }

            log.debug("{}: create_client_table_entry: client={} session={} request={}", .{
                self.replica,
                reply.header.client,
                session,
                request,
            });

            // Any duplicate .register requests should have received the same session number if the
            // client table entry already existed, or been dropped if a session was being committed:
            self.client_table().put(&.{
                .session = session,
                .reply = reply.ref(),
            });
            assert(self.client_table().count() <= constants.clients_max);
        }

        /// The caller owns the returned message, if any, which has exactly 1 reference.
        fn create_view_change_message(self: *Self, command: Command) *Message {
            assert(command == .do_view_change or command == .start_view);

            // We may send a start_view message in normal status to resolve a backup's view jump:
            assert(self.status == .normal or self.status == .view_change);

            const message = self.message_bus.get_message();
            defer self.message_bus.unref(message);

            message.header.* = .{
                .command = command,
                .cluster = self.cluster,
                .replica = self.replica,
                .view = self.view,
                // The latest normal view (as specified in the 2012 paper) is different to the view
                // number contained in the prepare headers we include in the body. The former shows
                // how recent a view change the replica participated in, which may be much higher.
                // We use the `timestamp` field to send this in addition to the current view number:
                .timestamp = if (command == .do_view_change) self.view_normal else 0,
                .op = self.op,
                // See the comment in `on_do_view_change()` for why `commit_min` is crucial:
                .commit = if (command == .do_view_change) self.commit_min else self.commit_max,
            };

            const count = self.copy_latest_headers_and_set_size(
                0,
                self.op,
                view_change_headers_count,
                message,
            );
            assert(count > 0); // We expect that self.op always exists.
            assert(@divExact(message.header.size, @sizeOf(Header)) == 1 + count);

            message.header.set_checksum_body(message.body());
            message.header.set_checksum();

            return message.ref();
        }

        /// The caller owns the returned message, if any, which has exactly 1 reference.
        fn create_message_from_header(self: *Self, header: Header) *Message {
            assert(header.replica == self.replica);
            assert(header.view == self.view or
                header.command == .request_start_view or
                header.command == .recovery);
            assert(header.size == @sizeOf(Header));

            const message = self.message_bus.pool.get_message();
            defer self.message_bus.unref(message);

            message.header.* = header;
            message.header.set_checksum_body(message.body());
            message.header.set_checksum();

            return message.ref();
        }

        /// Returns the op of the highest canonical message, according to this replica (the new
        /// primary) prior to loading the current view change's DVC quorum headers.
        /// When this replica participated in the last `view_normal`, this is just `replica.op`.
        ///
        /// - A *canonical* message was part of the last view_normal.
        /// - An *uncanonical* message may have been removed/changed by a prior view.
        /// - Canonical messages do not necessarily survive into the new view, but they take
        ///   precedence over uncanonical messages.
        /// - Canonical messages may be committed or uncommitted.
        ///
        /// Consider these logs:
        ///
        ///   replica 0: 4, 5, 6b, 7b, 8b  (commit_min=6b, primary, status=normal, view=X)
        ///   replica 1: 4, 5, 6b, --, --  (commit_min=5, backup, status=normal, view=X)
        ///   replica 2: 4, 5, 6a, --, 8b  (view<X)
        ///
        /// 1. Replica 0 crashes immediately after committing 6b.
        /// 2. Replicas 1 and 2 must determine the new chain HEAD.
        /// 3. 8b is discarded due to the gap in 7.
        /// 4. To distinguish between 6a and 6b (and safely discard 6a), the new primary trusts ops
        ///    from the DVC(s) with the greatest `view_normal`.
        fn primary_op_canonical_max(self: *const Self, view_normal_canonical: u64) usize {
            assert(self.replica_count > 1);
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);
            assert(self.do_view_change_quorum);
            assert(!self.repair_timeout.ticking);
            assert(self.journal.header_with_op(self.op) != null);
            assert(self.view_normal <= view_normal_canonical);

            if (self.view_normal == view_normal_canonical) return self.op;

            const uncanonical_op_count = std.math.min(
                // Do not reset any ops that we have already committed.
                self.op - self.commit_min,
                // The number of uncommitted ops cannot be more than the length of the pipeline.
                // Do not reset any ops that we did not include in our do_view_change message.
                constants.pipeline_max,
            );

            assert(uncanonical_op_count <= constants.pipeline_max);
            if (uncanonical_op_count == 0) return self.op;

            // * When uncanonical_op_count = self.op - self.commit_min,
            //   self.op - uncanonical_op_count = self.commit_min.
            // * When uncanonical_op_count = constants.pipeline_max,
            //   constants.pipeline_max < self.op - self.commit_min holds.
            const canonical_op_max = self.op - uncanonical_op_count;

            log.debug("{}: on_do_view_change: not canonical ops={}..{}", .{
                self.replica,
                canonical_op_max + 1,
                self.op,
            });

            assert(canonical_op_max <= self.op);
            assert(canonical_op_max >= self.commit_min);
            assert(canonical_op_max + constants.pipeline_max >= self.op);
            return canonical_op_max;
        }

        /// Discards uncommitted ops during a view change from after and including `op`.
        /// This is required to maximize availability in the presence of storage faults.
        /// Refer to the CTRL protocol from Protocol-Aware Recovery for Consensus-Based Storage.
        fn primary_discard_uncommitted_ops_from(self: *Self, op: u64, checksum: u128) void {
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);
            assert(self.repairs_allowed());

            assert(self.valid_hash_chain("primary_discard_uncommitted_ops_from"));

            const slot = self.journal.slot_with_op(op).?;
            assert(op > self.commit_max);
            assert(op <= self.op);
            assert(self.journal.header_with_op_and_checksum(op, checksum) != null);
            assert(self.journal.dirty.bit(slot));

            log.debug("{}: primary_discard_uncommitted_ops_from: ops={}..{} view={}", .{
                self.replica,
                op,
                self.op,
                self.view,
            });

            self.op = op - 1;
            self.journal.remove_entries_from(op);

            assert(self.journal.header_for_op(op) == null);
            assert(!self.journal.dirty.bit(slot));
            assert(!self.journal.faulty.bit(slot));

            // We require that `self.op` always exists. Rewinding `self.op` could change that.
            // However, we do this only as the primary within a view change, with all headers intact.
            assert(self.journal.header_with_op(self.op) != null);
        }

        /// Returns whether the replica is a backup for the current view.
        /// This may be used only when the replica status is normal.
        fn backup(self: *Self) bool {
            return !self.primary();
        }

        fn flush_loopback_queue(self: *Self) void {
            // There are four cases where a replica will send a message to itself:
            // However, of these four cases, all but one call send_message_to_replica().
            //
            // 1. In on_request(), the primary sends a synchronous prepare to itself, but this is
            //    done by calling on_prepare() directly, and subsequent prepare timeout retries will
            //    never resend to self.
            // 2. In on_prepare(), after writing to storage, the primary sends a (typically)
            //    asynchronous prepare_ok to itself.
            // 3. In on_start_view_change(), after receiving a quorum of start_view_change
            //    messages, the new primary sends a synchronous do_view_change to itself.
            // 4. In start_view_as_the_new_primary(), the new primary sends itself a prepare_ok
            //    message for each uncommitted message.
            if (self.loopback_queue) |message| {
                defer self.message_bus.unref(message);

                assert(message.next == null);
                self.loopback_queue = null;
                assert(message.header.replica == self.replica);
                self.on_message(message);
                // We do not call flush_loopback_queue() within on_message() to avoid recursion.
            }
            // We expect that delivering a prepare_ok or do_view_change message to ourselves will
            // not result in any further messages being added synchronously to the loopback queue.
            assert(self.loopback_queue == null);
        }

        fn ignore_prepare_ok(self: *Self, message: *const Message) bool {
            if (self.status != .normal) {
                log.debug("{}: on_prepare_ok: ignoring ({})", .{ self.replica, self.status });
                return true;
            }

            if (message.header.view < self.view) {
                log.debug("{}: on_prepare_ok: ignoring (older view)", .{self.replica});
                return true;
            }

            if (message.header.view > self.view) {
                // Another replica is treating us as the primary for a view we do not know about.
                // This may be caused by a fault in the network topology.
                log.warn("{}: on_prepare_ok: ignoring (newer view)", .{self.replica});
                return true;
            }

            if (self.backup()) {
                // This may be caused by a fault in the network topology.
                log.warn("{}: on_prepare_ok: ignoring (backup)", .{self.replica});
                return true;
            }

            return false;
        }

        fn ignore_repair_message(self: *Self, message: *const Message) bool {
            assert(message.header.command == .request_start_view or
                message.header.command == .request_headers or
                message.header.command == .request_prepare or
                message.header.command == .headers or
                message.header.command == .nack_prepare);

            const command: []const u8 = @tagName(message.header.command);

            if (self.status != .normal and self.status != .view_change) {
                log.debug("{}: on_{s}: ignoring ({})", .{ self.replica, command, self.status });
                return true;
            }

            if (message.header.view < self.view) {
                log.debug("{}: on_{s}: ignoring (older view)", .{ self.replica, command });
                return true;
            }

            if (message.header.view > self.view) {
                log.debug("{}: on_{s}: ignoring (newer view)", .{ self.replica, command });
                return true;
            }

            if (self.ignore_repair_message_during_view_change(message)) return true;

            if (message.header.replica == self.replica) {
                log.warn("{}: on_{s}: ignoring (self)", .{ self.replica, command });
                return true;
            }

            if (self.primary_index(self.view) != self.replica) {
                switch (message.header.command) {
                    // Only the primary may receive these messages:
                    .request_start_view, .nack_prepare => {
                        log.warn("{}: on_{s}: ignoring (backup)", .{ self.replica, command });
                        return true;
                    },
                    // Only the primary may answer a request for a prepare without a context:
                    .request_prepare => if (message.header.timestamp == 0) {
                        log.warn("{}: on_{s}: ignoring (no context)", .{ self.replica, command });
                        return true;
                    },
                    else => {},
                }
            }

            if (message.header.command == .nack_prepare and self.status == .normal) {
                log.debug("{}: on_{s}: ignoring (view started)", .{ self.replica, command });
                return true;
            }

            // Only allow repairs for same view as defense-in-depth:
            assert(message.header.view == self.view);
            return false;
        }

        fn ignore_repair_message_during_view_change(self: *Self, message: *const Message) bool {
            if (self.status != .view_change) return false;

            const command: []const u8 = @tagName(message.header.command);

            switch (message.header.command) {
                .request_start_view => {
                    log.debug("{}: on_{s}: ignoring (view change)", .{ self.replica, command });
                    return true;
                },
                .request_headers, .request_prepare => {
                    if (self.primary_index(self.view) != message.header.replica) {
                        log.debug("{}: on_{s}: ignoring (view change, requested by backup)", .{
                            self.replica,
                            command,
                        });
                        return true;
                    }
                },
                .headers, .nack_prepare => {
                    if (self.primary_index(self.view) != self.replica) {
                        log.debug("{}: on_{s}: ignoring (view change, received by backup)", .{
                            self.replica,
                            command,
                        });
                        return true;
                    } else if (!self.do_view_change_quorum) {
                        log.debug("{}: on_{s}: ignoring (view change, waiting for quorum)", .{
                            self.replica,
                            command,
                        });
                        return true;
                    }
                },
                else => unreachable,
            }

            return false;
        }

        fn ignore_request_message(self: *Self, message: *Message) bool {
            assert(message.header.command == .request);

            if (self.status != .normal) {
                log.debug("{}: on_request: ignoring ({s})", .{ self.replica, self.status });
                return true;
            }

            if (self.ignore_request_message_backup(message)) return true;
            if (self.ignore_request_message_duplicate(message)) return true;
            if (self.ignore_request_message_preparing(message)) return true;

            // Verify that the new request will fit in the WAL.
            // The message's op hasn't been assigned yet, but it will be `self.op + 1`.
            if (self.op == self.op_checkpoint_trigger()) {
                log.debug("{}: on_request: ignoring op={} (too far ahead, checkpoint_trigger={})", .{
                    self.replica,
                    self.op + 1,
                    self.op_checkpoint,
                });
                return true;
            }

            return false;
        }

        /// Returns whether the request is stale, or a duplicate of the latest committed request.
        /// Resends the reply to the latest request if the request has been committed.
        fn ignore_request_message_duplicate(self: *Self, message: *const Message) bool {
            assert(self.status == .normal);
            assert(self.primary());

            assert(message.header.command == .request);
            assert(message.header.client > 0);
            assert(message.header.view <= self.view); // See ignore_request_message_backup().
            assert(message.header.context == 0 or message.header.operation != .register);
            assert(message.header.request == 0 or message.header.operation != .register);

            if (self.client_table().get(message.header.client)) |entry| {
                assert(entry.reply.header.command == .reply);
                assert(entry.reply.header.client == message.header.client);

                if (message.header.operation == .register) {
                    // Fall through below to check if we should resend the .register session reply.
                } else if (entry.session > message.header.context) {
                    // The client must not reuse the ephemeral client ID when registering a new session.
                    log.err("{}: on_request: ignoring older session (client bug)", .{self.replica});
                    return true;
                } else if (entry.session < message.header.context) {
                    // This cannot be because of a partition since we check the client's view number.
                    log.err("{}: on_request: ignoring newer session (client bug)", .{self.replica});
                    return true;
                }

                if (entry.reply.header.request > message.header.request) {
                    log.debug("{}: on_request: ignoring older request", .{self.replica});
                    return true;
                } else if (entry.reply.header.request == message.header.request) {
                    if (message.header.checksum == entry.reply.header.parent) {
                        assert(entry.reply.header.operation == message.header.operation);

                        log.debug("{}: on_request: replying to duplicate request", .{self.replica});
                        self.message_bus.send_message_to_client(message.header.client, entry.reply);
                        return true;
                    } else {
                        log.err("{}: on_request: request collision (client bug)", .{self.replica});
                        return true;
                    }
                } else if (entry.reply.header.request + 1 == message.header.request) {
                    if (message.header.parent == entry.reply.header.checksum) {
                        // The client has proved that they received our last reply.
                        log.debug("{}: on_request: new request", .{self.replica});
                        return false;
                    } else {
                        // The client may have only one request inflight at a time.
                        log.err("{}: on_request: ignoring new request (client bug)", .{
                            self.replica,
                        });
                        return true;
                    }
                } else {
                    log.err("{}: on_request: ignoring newer request (client bug)", .{self.replica});
                    return true;
                }
            } else if (message.header.operation == .register) {
                log.debug("{}: on_request: new session", .{self.replica});
                return false;
            } else if (self.pipeline_prepare_for_client(message.header.client)) |_| {
                // The client registered with the previous primary, which committed and replied back
                // to the client before the view change, after which the register operation was
                // reloaded into the pipeline to be driven to completion by the new primary, which
                // now receives a request from the client that appears to have no session.
                // However, the session is about to be registered, so we must wait for it to commit.
                log.debug("{}: on_request: waiting for session to commit", .{self.replica});
                return true;
            } else {
                // We must have all commits to know whether a session has been evicted. For example,
                // there is the risk of sending an eviction message (even as the primary) if we are
                // partitioned and don't yet know about a session. We solve this by having clients
                // include the view number and rejecting messages from clients with newer views.
                log.err("{}: on_request: no session", .{self.replica});
                self.send_eviction_message_to_client(message.header.client);
                return true;
            }
        }

        /// Returns whether the replica is eligible to process this request as the primary.
        /// Takes the client's perspective into account if the client is aware of a newer view.
        /// Forwards requests to the primary if the client has an older view.
        fn ignore_request_message_backup(self: *Self, message: *Message) bool {
            assert(self.status == .normal);
            assert(message.header.command == .request);

            // The client is aware of a newer view:
            // Even if we think we are the primary, we may be partitioned from the rest of the cluster.
            // We therefore drop the message rather than flood our partition with traffic.
            if (message.header.view > self.view) {
                log.debug("{}: on_request: ignoring (newer view)", .{self.replica});
                return true;
            } else if (self.primary()) {
                return false;
            }

            if (message.header.operation == .register) {
                // We do not forward `.register` requests for the sake of `Header.peer_type()`.
                // This enables the MessageBus to identify client connections on the first message.
                log.debug("{}: on_request: ignoring (backup, register)", .{self.replica});
            } else if (message.header.view < self.view) {
                // The client may not know who the primary is, or may be retrying after a primary failure.
                // We forward to the new primary ahead of any client retry timeout to reduce latency.
                // Since the client is already connected to all replicas, the client may yet receive the
                // reply from the new primary directly.
                log.debug("{}: on_request: forwarding (backup)", .{self.replica});
                self.send_message_to_replica(self.primary_index(self.view), message);
            } else {
                assert(message.header.view == self.view);
                // The client has the correct view, but has retried against a backup.
                // This may mean that the primary is down and that we are about to do a view change.
                // There is also not much we can do as the client already knows who the primary is.
                // We do not forward as this would amplify traffic on the network.

                // TODO This may also indicate a client-primary partition. If we see enough of these,
                // should we trigger a view change to select a primary that clients can reach?
                // This is a question of weighing the probability of a partition vs routing error.
                log.debug("{}: on_request: ignoring (backup, same view)", .{self.replica});
            }

            assert(self.backup());
            return true;
        }

        fn ignore_request_message_preparing(self: *Self, message: *const Message) bool {
            assert(self.status == .normal);
            assert(self.primary());

            assert(message.header.command == .request);
            assert(message.header.client > 0);
            assert(message.header.view <= self.view); // See ignore_request_message_backup().

            if (self.pipeline_prepare_for_client(message.header.client)) |prepare| {
                assert(prepare.message.header.command == .prepare);
                assert(prepare.message.header.client == message.header.client);
                assert(prepare.message.header.op > self.commit_max);

                if (message.header.checksum == prepare.message.header.context) {
                    log.debug("{}: on_request: ignoring (already preparing)", .{self.replica});
                    return true;
                } else {
                    log.err("{}: on_request: ignoring (client forked)", .{self.replica});
                    return true;
                }
            }

            if (self.pipeline.full()) {
                log.debug("{}: on_request: ignoring (pipeline full)", .{self.replica});
                return true;
            }

            return false;
        }

        fn ignore_view_change_message(self: *Self, message: *const Message) bool {
            assert(message.header.command == .start_view_change or
                message.header.command == .do_view_change or
                message.header.command == .start_view);
            assert(message.header.view > 0); // The initial view is already zero.

            const command: []const u8 = @tagName(message.header.command);

            // 4.3 Recovery
            // While a replica's status is recovering it does not participate in either the request
            // processing protocol or the view change protocol.
            // This is critical for correctness (to avoid data loss):
            if (self.status == .recovering) {
                log.debug("{}: on_{s}: ignoring (recovering)", .{ self.replica, command });
                return true;
            }

            if (message.header.view < self.view) {
                log.debug("{}: on_{s}: ignoring (older view)", .{ self.replica, command });
                return true;
            }

            if (message.header.view == self.view and self.status == .normal) {
                log.debug("{}: on_{s}: ignoring (view started)", .{ self.replica, command });
                return true;
            }

            // These may be caused by faults in the network topology.
            switch (message.header.command) {
                .start_view_change, .start_view => {
                    if (message.header.replica == self.replica) {
                        log.warn("{}: on_{s}: ignoring (self)", .{ self.replica, command });
                        return true;
                    }
                },
                .do_view_change => {
                    if (self.primary_index(message.header.view) != self.replica) {
                        log.warn("{}: on_{s}: ignoring (backup)", .{ self.replica, command });
                        return true;
                    }
                },
                else => unreachable,
            }

            return false;
        }

        fn is_repair(self: *const Self, message: *const Message) bool {
            assert(message.header.command == .prepare);

            if (self.status == .normal) {
                if (message.header.view < self.view) return true;
                if (message.header.view == self.view and message.header.op <= self.op) return true;
            } else if (self.status == .view_change) {
                if (message.header.view < self.view) return true;
                // The view has already started or is newer.
            }

            return false;
        }

        /// Returns whether the replica is the primary for the current view.
        /// This may be used only when the replica status is normal.
        fn primary(self: *const Self) bool {
            assert(self.status == .normal);
            return self.primary_index(self.view) == self.replica;
        }

        /// Returns the index into the configuration of the primary for a given view.
        fn primary_index(self: *const Self, view: u32) u8 {
            return @intCast(u8, @mod(view, self.replica_count));
        }

        /// Advances `op` to where we need to be before `header` can be processed as a prepare.
        ///
        /// This function temporarily violates the "replica.op must exist in WAL" invariant.
        fn jump_to_newer_op_in_normal_status(self: *Self, header: *const Header) void {
            assert(self.status == .normal);
            assert(self.backup());
            assert(header.view == self.view);
            assert(header.op > self.op + 1);
            // We may have learned of a higher `commit_max` through a commit message before jumping
            // to a newer op that is less than `commit_max` but greater than `commit_min`:
            assert(header.op > self.commit_min);
            // Never overwrite an op that still needs to be checkpointed.
            assert(header.op <= self.op_checkpoint_trigger());

            log.debug("{}: jump_to_newer_op: advancing: op={}..{} checksum={}..{}", .{
                self.replica,
                self.op,
                header.op - 1,
                self.journal.header_with_op(self.op).?.checksum,
                header.parent,
            });

            self.op = header.op - 1;
            assert(self.op >= self.commit_min);
            assert(self.op + 1 == header.op);
            assert(self.journal.header_with_op(self.op) == null);
        }

        fn message_body_as_headers(message: *const Message) []const Header {
            assert(message.header.size > @sizeOf(Header)); // Body must contain at least one header.
            assert(message.header.command == .do_view_change or
                message.header.command == .start_view or
                message.header.command == .headers or
                message.header.command == .recovery_response);

            const headers = std.mem.bytesAsSlice(
                Header,
                message.buffer[@sizeOf(Header)..message.header.size],
            );

            for (headers[0 .. headers.len - 1]) |header, index| {
                // Headers must be provided in reverse order for the sake of `repair_header()`.
                // Otherwise, headers may never be repaired where the hash chain never connects.
                assert(header.op > headers[index + 1].op);
            }

            return headers;
        }

        /// Returns whether the highest known op is certain.
        ///
        /// After recovering the WAL, there are 2 possible outcomes:
        /// * All entries valid. The highest op is certain, and safe to set as `replica.op`.
        /// * One or more entries are faulty. The highest op isn't certain — it may be one of the
        ///   broken entries.
        ///
        /// The replica must refrain from repairing any faulty slots until the highest op is known.
        /// Otherwise, if we were to repair a slot while uncertain of `replica.op`:
        ///
        /// * we may nack an op that we shouldn't, or
        /// * we may replace a prepared op that we were guaranteeing for the primary, potentially
        ///   forking the log.
        ///
        ///
        /// Test for a fault the right of the current op. The fault might be our true op, and
        /// sharing our current `replica.op` might cause the cluster's op to likewise regress.
        ///
        /// Note that for our purposes here, we only care about entries that were faulty during
        /// WAL recovery, not ones that were found to be faulty after the fact (e.g. due to
        /// `request_prepare`).
        ///
        /// Cases (`✓`: `replica.op_checkpoint`, `✗`: faulty, `o`: `replica.op`):
        /// * ` ✓ o ✗ `: View change is unsafe.
        /// * ` ✗ ✓ o `: View change is unsafe.
        /// * ` ✓ ✗ o `: View change is safe.
        /// * ` ✓ = o `: View change is unsafe if any slots are faulty.
        ///              (`replica.op_checkpoint` == `replica.op`).
        // TODO Use this function once we switch from recovery protocol to the superblock.
        // If there is an "unsafe" fault, we will need to request a start_view from the primary to
        // learn the op.
        fn op_certain(self: *const Self) bool {
            assert(self.status == .recovering);
            assert(self.op_checkpoint <= self.op);

            const slot_op_checkpoint = self.journal.slot_for_op(self.op_checkpoint).index;
            const slot_op = self.journal.slot_with_op(self.op).?.index;
            const slot_known_range = vsr.SlotRange{
                .head = slot_op_checkpoint,
                .tail = slot_op,
            };

            var iterator = self.journal.faulty.bits.iterator(.{ .kind = .set });
            while (iterator.next()) |slot| {
                // The command is `reserved` when the entry was found faulty during WAL recovery.
                // Faults found after WAL recovery are not relevant, because we know their op.
                if (self.journal.headers[slot.index].command == .reserved) {
                    if (slot_op_checkpoint == slot_op or
                        !slot_known_range.contains(slot))
                    {
                        log.warn("{}: op_certain: op not known (faulty_slot={}, op={}, op_checkpoint={})", .{
                            self.replica,
                            slot.index,
                            self.op,
                            self.op_checkpoint,
                        });
                        return false;
                    }
                }
            }
            return true;
        }

        /// Returns the op that will be `op_checkpoint` after the next checkpoint.
        ///
        /// For a replica with journal_slot_count=8 and lsm_batch_multiple=2:
        ///
        ///   checkpoint() call      0   1   2   3
        ///   op_checkpoint          0   5  11  17
        ///   op_checkpoint_next     5  11  17  23
        ///   op_checkpoint_trigger  7  13  19  25
        ///
        ///     commit log (ops)           │ write-ahead log (slots)
        ///     0   4   8   2   6   0   4  │ 0---4---
        ///   0 ─────✓·%                   │ 01234✓6%   initial log fill
        ///   1 ───────────✓·%             │ 890✓2%45   first wrap of log
        ///   2 ─────────────────✓·%       │ 6✓8%0123   second wrap of log
        ///   3 ───────────────────────✓·% │ 4%67890✓   third wrap of log
        ///
        /// Legend:
        ///
        ///   ─/✓  op on disk at checkpoint
        ///   ·/%  op in memory at checkpoint
        ///     ✓  op_checkpoint
        ///     %  op_checkpoint_trigger
        ///
        fn op_checkpoint_next(self: *const Self) u64 {
            assert(self.op_checkpoint <= self.commit_min);
            assert(self.op_checkpoint <= self.op);
            assert(self.op_checkpoint == 0 or
                (self.op_checkpoint + 1) % constants.lsm_batch_multiple == 0);

            const op = if (self.op_checkpoint == 0)
                // First wrap: op_checkpoint_next = 8-2-1 = 5
                constants.journal_slot_count - constants.lsm_batch_multiple - 1
            else
                // Second wrap: op_checkpoint_next = 5+8-2 = 11
                // Third wrap: op_checkpoint_next = 11+8-2 = 17
                self.op_checkpoint + constants.journal_slot_count - constants.lsm_batch_multiple;
            assert((op + 1) % constants.lsm_batch_multiple == 0);
            // The checkpoint always advances.
            assert(op > self.op_checkpoint);

            return op;
        }

        /// Returns the next op that will trigger a checkpoint.
        ///
        /// Receiving and storing an op higher than `op_checkpoint_trigger()` is forbidden; doing so
        /// would overwrite a message (or the slot of a message) that has not yet been committed and
        /// checkpointed.
        ///
        /// See `op_checkpoint_next` for more detail.
        fn op_checkpoint_trigger(self: *const Self) u64 {
            return self.op_checkpoint_next() + constants.lsm_batch_multiple;
        }

        /// Finds the header with the highest op number in a slice of headers from a replica.
        /// The headers must be continuous, in reverse order, all connected, and with no gaps.
        fn op_highest(headers: []const Header) u64 {
            assert(headers.len > 0);

            for (headers) |header, index| {
                assert(header.valid_checksum());
                assert(header.invalid() == null);
                assert(header.command == .prepare);

                if (index > 0) {
                    assert(header.op + 1 == headers[index - 1].op);
                    assert(header.checksum == headers[index - 1].parent);
                }
            }

            return headers[0].op;
        }

        /// Panics if immediate neighbors in the same view would have a broken hash chain.
        /// Assumes gaps and does not require that a preceeds b.
        fn panic_if_hash_chain_would_break_in_the_same_view(
            self: *const Self,
            a: *const Header,
            b: *const Header,
        ) void {
            assert(a.command == .prepare);
            assert(b.command == .prepare);
            assert(a.cluster == b.cluster);
            if (a.view == b.view and a.op + 1 == b.op and a.checksum != b.parent) {
                assert(a.valid_checksum());
                assert(b.valid_checksum());
                log.err("{}: panic_if_hash_chain_would_break: a: {}", .{ self.replica, a });
                log.err("{}: panic_if_hash_chain_would_break: b: {}", .{ self.replica, b });
                @panic("hash chain would break");
            }
        }

        /// Searches the pipeline for a prepare for a given op and checksum.
        /// When `checksum` is `null`, match any checksum.
        fn pipeline_prepare_for_op_and_checksum(self: *Self, op: u64, checksum: ?u128) ?*Prepare {
            assert(self.status == .normal or self.status == .view_change);

            // To optimize the search, we can leverage the fact that the pipeline is ordered and
            // continuous.
            if (self.pipeline.count == 0) return null;
            const head_op = self.pipeline.head_ptr().?.message.header.op;
            const tail_op = self.pipeline.tail_ptr().?.message.header.op;
            if (op < head_op) return null;
            if (op > tail_op) return null;

            const pipeline_prepare = self.pipeline.get_ptr(op - head_op).?;
            assert(pipeline_prepare.message.header.op == op);

            if (checksum == null or pipeline_prepare.message.header.checksum == checksum.?) {
                return pipeline_prepare;
            } else {
                return null;
            }
        }

        /// Searches the pipeline for a prepare for a given client.
        fn pipeline_prepare_for_client(self: *Self, client: u128) ?*Prepare {
            assert(self.status == .normal);
            assert(self.primary());
            assert(self.commit_min == self.commit_max);

            var op = self.commit_max + 1;
            var parent = self.journal.header_with_op(self.commit_max).?.checksum;
            var iterator = self.pipeline.iterator_mutable();
            while (iterator.next_ptr()) |prepare| {
                assert(prepare.message.header.command == .prepare);
                assert(prepare.message.header.op == op);
                assert(prepare.message.header.parent == parent);

                // A client may have multiple requests in the pipeline if these were committed by
                // the previous primary and were reloaded into the pipeline after a view change.
                if (prepare.message.header.client == client) return prepare;

                parent = prepare.message.header.checksum;
                op += 1;
            }

            assert(self.pipeline.count <= constants.pipeline_max);
            assert(self.commit_max + self.pipeline.count == op - 1);
            assert(self.commit_max + self.pipeline.count == self.op);

            return null;
        }

        /// Searches the pipeline for a prepare for a given client and checksum.
        /// Passing the prepare_ok message prevents these u128s from being accidentally swapped.
        /// Asserts that the returned prepare, if any, exactly matches the prepare_ok.
        fn pipeline_prepare_for_prepare_ok(self: *Self, ok: *const Message) ?*Prepare {
            assert(ok.header.command == .prepare_ok);

            assert(self.status == .normal);
            assert(self.primary());

            const prepare = self.pipeline_prepare_for_client(ok.header.client) orelse {
                log.debug("{}: pipeline_prepare_for_prepare_ok: not preparing", .{self.replica});
                return null;
            };

            if (ok.header.context != prepare.message.header.checksum) {
                // This can be normal, for example, if an old prepare_ok is replayed.
                log.debug("{}: pipeline_prepare_for_prepare_ok: preparing a different client op", .{
                    self.replica,
                });
                return null;
            }

            assert(prepare.message.header.parent == ok.header.parent);
            assert(prepare.message.header.client == ok.header.client);
            assert(prepare.message.header.request == ok.header.request);
            assert(prepare.message.header.cluster == ok.header.cluster);
            assert(prepare.message.header.epoch == ok.header.epoch);
            // A prepare may be committed in the same view or in a newer view:
            assert(prepare.message.header.view <= ok.header.view);
            assert(prepare.message.header.op == ok.header.op);
            assert(prepare.message.header.commit == ok.header.commit);
            assert(prepare.message.header.timestamp == ok.header.timestamp);
            assert(prepare.message.header.operation == ok.header.operation);

            return prepare;
        }

        fn recover(self: *Self) void {
            assert(self.status == .recovering);
            assert(self.replica_count > 1);

            log.debug("{}: recover: sending recovery messages nonce={}", .{
                self.replica,
                self.recovery_nonce,
            });

            self.send_header_to_other_replicas(.{
                .command = .recovery,
                .cluster = self.cluster,
                .context = self.recovery_nonce,
                .replica = self.replica,
            });
        }

        /// Starting from the latest journal entry, backfill any missing or disconnected headers.
        /// A header is disconnected if it breaks the chain with its newer neighbor to the right.
        /// Since we work back from the latest entry, we should always be able to fix the chain.
        /// Once headers are connected, backfill any dirty or faulty prepares.
        fn repair(self: *Self) void {
            if (!self.repair_timeout.ticking) {
                log.debug("{}: repair: ignoring (optimistic, not ticking)", .{self.replica});
                return;
            }

            self.repair_timeout.reset();

            assert(self.status == .normal or self.status == .view_change);
            assert(self.repairs_allowed());

            assert(self.op_checkpoint <= self.op);
            assert(self.op_checkpoint <= self.commit_min);
            assert(self.commit_min <= self.op);
            assert(self.commit_min <= self.commit_max);
            assert(self.journal.header_with_op(self.op) != null);

            // The replica repairs backwards from `commit_max`. But if `commit_max` is too high
            // (>1 WAL ahead), then bound it such that uncommitted WAL entries are not overwritten.
            const commit_max_limit = std.math.min(self.commit_max, self.op_checkpoint_trigger());

            // Request outstanding committed prepares to advance our op number:
            // This handles the case of an idle cluster, where a backup will not otherwise advance.
            // This is not required for correctness, but for durability.
            if (self.op < commit_max_limit) {
                // If the primary repairs during a view change, it will have already advanced
                // `self.op` to the latest op according to the quorum of `do_view_change` messages
                // received, so we must therefore be a backup in normal status:
                assert(self.status == .normal);
                assert(self.backup());
                log.debug("{}: repair: op={} < commit_max_limit={}, commit_max={}", .{
                    self.replica,
                    self.op,
                    commit_max_limit,
                    self.commit_max,
                });
                // We need to advance our op number and therefore have to `request_prepare`,
                // since only `on_prepare()` can do this, not `repair_header()` in `on_headers()`.
                self.send_header_to_replica(self.primary_index(self.view), .{
                    .command = .request_prepare,
                    // We cannot yet know the checksum of the prepare so we set the context and
                    // timestamp to 0: Context is optional when requesting from the primary but
                    // required otherwise.
                    .context = 0,
                    .timestamp = 0,
                    .cluster = self.cluster,
                    .replica = self.replica,
                    .view = self.view,
                    .op = commit_max_limit,
                });
                return;
            }

            // Request any missing or disconnected headers:
            // TODO Snapshots: Ensure that self.commit_min op always exists in the journal.
            var broken = self.journal.find_latest_headers_break_between(self.commit_min, self.op);
            if (broken) |range| {
                log.debug("{}: repair: break: view={} op_min={} op_max={} (commit={}..{} op={})", .{
                    self.replica,
                    self.view,
                    range.op_min,
                    range.op_max,
                    self.commit_min,
                    self.commit_max,
                    self.op,
                });
                assert(range.op_min > self.commit_min);
                assert(range.op_max < self.op);
                // A range of `op_min=0` or `op_max=0` should be impossible as a header break:
                // This is the root op that is prepared when the cluster is initialized.
                assert(range.op_min > 0);
                assert(range.op_max > 0);

                if (self.choose_any_other_replica()) |replica| {
                    self.send_header_to_replica(replica, .{
                        .command = .request_headers,
                        .cluster = self.cluster,
                        .replica = self.replica,
                        .view = self.view,
                        .commit = range.op_min,
                        .op = range.op_max,
                    });
                }
                return;
            }

            // Assert that all headers are now present and connected with a perfect hash chain:
            // TODO(State Transfer): This may fail if the commit max is too far ahead and we
            // couldn't repair it without jumping ahead on the WAL.
            assert(self.op >= self.commit_max);
            assert(self.valid_hash_chain_between(self.commit_min, self.op));

            // Request and repair any dirty or faulty prepares:
            if (self.journal.dirty.count > 0) return self.repair_prepares();

            // Commit ops, which may in turn discover faulty prepares and drive more repairs:
            if (self.commit_min < self.commit_max) {
                assert(self.replica_count > 1);
                self.commit_journal(self.commit_max);
                return;
            }

            if (self.status == .view_change and self.primary_index(self.view) == self.replica) {
                if (self.primary_repair_pipeline_op() != null) return self.primary_repair_pipeline();
                // Start the view as the new primary:
                self.start_view_as_the_new_primary();
            }
        }

        /// Decide whether or not to insert or update a header:
        ///
        /// A repair may never advance or replace `self.op` (critical for correctness):
        ///
        /// Repairs must always backfill in behind `self.op` but may never advance `self.op`.
        /// Otherwise, a split-brain primary may reapply an op that was removed through a view
        /// change, which could be committed by a higher `commit_max` number in a commit message.
        ///
        /// See this commit message for an example:
        /// https://github.com/coilhq/tigerbeetle/commit/6119c7f759f924d09c088422d5c60ac6334d03de
        ///
        /// Our guiding principles around repairs in general:
        ///
        /// * The latest op makes sense of everything else and must not be replaced with a different
        /// op or advanced except by the primary in the current view.
        ///
        /// * Do not jump to a view in normal status without receiving a start_view message.
        ///
        /// * Do not commit until the hash chain between `self.commit_min` and `self.op` is fully
        /// connected, to ensure that all the ops in this range are correct.
        ///
        /// * Ensure that `self.commit_max` is never advanced for a newer view without first
        /// receiving a start_view message, otherwise `self.commit_max` may refer to different ops.
        ///
        /// * Ensure that `self.op` is never advanced by a repair since repairs may occur in a view
        /// change where the view has not yet started.
        ///
        /// * Do not assume that an existing op with a older viewstamp can be replaced by an op with
        /// a newer viewstamp, but only compare ops in the same view or with reference to the chain.
        /// See Figure 3.7 on page 41 in Diego Ongaro's Raft thesis for an example of where an op
        /// with an older view number may be committed instead of an op with a newer view number:
        /// http://web.stanford.edu/~ouster/cgi-bin/papers/OngaroPhD.pdf.
        ///
        /// * Do not replace an op belonging to the current WAL wrap with an op belonging to a
        ///   previous wrap. In other words, don't repair checkpointed ops.
        ///
        fn repair_header(self: *Self, header: *const Header) bool {
            assert(header.valid_checksum());
            assert(header.invalid() == null);
            assert(header.command == .prepare);

            switch (self.status) {
                .normal => assert(header.view <= self.view),
                .view_change => assert(header.view <= self.view),
                else => unreachable,
            }

            if (header.op > self.op) {
                log.debug("{}: repair_header: op={} checksum={} (advances hash chain head)", .{
                    self.replica,
                    header.op,
                    header.checksum,
                });
                return false;
            } else if (header.op == self.op and !self.journal.has(header)) {
                assert(self.journal.header_with_op(self.op) != null);
                log.debug("{}: repair_header: op={} checksum={} (changes hash chain head)", .{
                    self.replica,
                    header.op,
                    header.checksum,
                });
                return false;
            }

            if (header.op <= self.op_checkpoint) {
                if (header.op == 0 and self.op_checkpoint == 0) {
                    // Repairing the root op is allowed until the first checkpoint.
                } else {
                    // It is critical that we do not repair checkpointed ops; their slots now belong
                    // to the next wrap of the log, and overwriting a new op with an old op is a
                    // correctness violation.
                    log.debug("{}: repair_header: false (precedes self.op_checkpoint={})", .{
                        self.replica,
                        self.op_checkpoint,
                    });
                    return false;
                }
            }

            if (self.journal.header_for_prepare(header)) |existing| {
                if (existing.checksum == header.checksum) {
                    if (self.journal.has_clean(header)) {
                        log.debug("{}: repair_header: op={} checksum={} (checksum clean)", .{
                            self.replica,
                            header.op,
                            header.checksum,
                        });
                        return false;
                    } else {
                        log.debug("{}: repair_header: op={} checksum={} (checksum dirty)", .{
                            self.replica,
                            header.op,
                            header.checksum,
                        });
                    }
                } else if (existing.view == header.view) {
                    // The journal must have wrapped:
                    // We expect that the same view and op would have had the same checksum.
                    assert(existing.op != header.op);
                    if (existing.op > header.op) {
                        log.debug("{}: repair_header: op={} checksum={} (same view, newer op)", .{
                            self.replica,
                            header.op,
                            header.checksum,
                        });
                    } else {
                        log.debug("{}: repair_header: op={} checksum={} (same view, older op)", .{
                            self.replica,
                            header.op,
                            header.checksum,
                        });
                    }
                } else {
                    assert(existing.view != header.view);
                    assert(existing.op == header.op or existing.op != header.op);

                    log.debug("{}: repair_header: op={} checksum={} (different view)", .{
                        self.replica,
                        header.op,
                        header.checksum,
                    });
                }
            } else {
                log.debug("{}: repair_header: op={} checksum={} (gap)", .{
                    self.replica,
                    header.op,
                    header.checksum,
                });
            }

            assert(header.op < self.op or
                self.journal.header_with_op(self.op).?.checksum == header.checksum);

            if (!self.repair_header_would_connect_hash_chain(header)) {
                // We cannot replace this op until we are sure that this would not:
                // 1. undermine any prior prepare_ok guarantee made to the primary, and
                // 2. leak stale ops back into our in-memory headers (and so into a view change).
                log.debug("{}: repair_header: op={} checksum={} (disconnected from hash chain)", .{
                    self.replica,
                    header.op,
                    header.checksum,
                });
                return false;
            }

            if (header.op <= self.commit_min) {
                if (self.journal.header_with_op(header.op)) |existing| {
                    // If we already committed this op, the repair must be the identical message.
                    assert(header.checksum == existing.checksum);
                }
            }

            self.journal.set_header_as_dirty(header);
            return true;
        }

        /// If we repair this header, would this connect the hash chain through to the latest op?
        /// This offers a strong guarantee that may be used to replace an existing op.
        ///
        /// Here is an example of what could go wrong if we did not check for complete connection:
        ///
        /// 1. We do a prepare that's going to be committed.
        /// 2. We do a stale prepare to the right, ignoring the hash chain break to the left.
        /// 3. We do another stale prepare that replaces the first since it connects to the second.
        ///
        /// This would violate our quorum replication commitment to the primary.
        /// The mistake in this example was not that we ignored the break to the left, which we must
        /// do to repair reordered ops, but that we did not check for connection to the right.
        fn repair_header_would_connect_hash_chain(self: *Self, header: *const Header) bool {
            var entry = header;

            while (entry.op < self.op) {
                if (self.journal.next_entry(entry)) |next| {
                    if (entry.checksum == next.parent) {
                        assert(entry.view <= next.view);
                        assert(entry.op + 1 == next.op);
                        entry = next;
                    } else {
                        return false;
                    }
                } else {
                    return false;
                }
            }

            assert(entry.op == self.op);
            assert(entry.checksum == self.journal.header_with_op(self.op).?.checksum);
            return true;
        }

        /// Reads prepares into the pipeline (before we start the view as the new primary).
        fn primary_repair_pipeline(self: *Self) void {
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);
            assert(self.commit_max < self.op);
            assert(self.journal.dirty.count == 0);

            if (self.repairing_pipeline) {
                log.debug("{}: primary_repair_pipeline: already repairing...", .{self.replica});
                return;
            }

            log.debug("{}: primary_repair_pipeline: repairing", .{self.replica});

            assert(!self.repairing_pipeline);
            self.repairing_pipeline = true;

            self.primary_repair_pipeline_read();
        }

        /// Discard messages from the prepare pipeline.
        /// Retain uncommitted messages that belong in the current view to maximize durability.
        fn primary_repair_pipeline_diff(self: *Self) void {
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);

            // Discard messages from the front of the pipeline that committed since we were primary.
            while (self.pipeline.head_ptr()) |prepare| {
                if (prepare.message.header.op > self.commit_max) break;

                self.message_bus.unref(self.pipeline.pop().?.message);
            }

            // Discard the whole pipeline if it is now disconnected from the WAL's hash chain.
            if (self.pipeline.head_ptr()) |pipeline_head| {
                const parent = self.journal.header_with_op_and_checksum(
                    pipeline_head.message.header.op - 1,
                    pipeline_head.message.header.parent,
                );
                if (parent == null) {
                    while (self.pipeline.pop()) |prepare| self.message_bus.unref(prepare.message);
                    assert(self.pipeline.count == 0);
                }
            }

            // Discard messages from the back of the pipeline that are not part of this view.
            while (self.pipeline.tail_ptr()) |prepare| {
                if (self.journal.has(prepare.message.header)) break;

                self.message_bus.unref(self.pipeline.pop_tail().?.message);
            }

            log.debug("{}: primary_repair_pipeline_diff: {} prepare(s)", .{
                self.replica,
                self.pipeline.count,
            });

            self.verify_pipeline();

            // Do not reset `repairing_pipeline` here as this must be reset by the read callback.
            // Otherwise, we would be making `primary_repair_pipeline()` reentrant.
        }

        /// Returns the next `op` number that needs to be read into the pipeline.
        fn primary_repair_pipeline_op(self: *Self) ?u64 {
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);

            // We cannot rely on `pipeline.count` below unless the pipeline has first been diffed.
            self.primary_repair_pipeline_diff();

            const op = self.commit_max + self.pipeline.count + 1;
            if (op <= self.op) return op;

            assert(self.commit_max + self.pipeline.count == self.op);
            return null;
        }

        fn primary_repair_pipeline_read(self: *Self) void {
            assert(self.repairing_pipeline);
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);

            if (self.primary_repair_pipeline_op()) |op| {
                assert(op > self.commit_max);
                assert(op <= self.op);
                assert(self.commit_max + self.pipeline.count + 1 == op);

                const checksum = self.journal.header_with_op(op).?.checksum;

                log.debug("{}: primary_repair_pipeline_read: op={} checksum={}", .{
                    self.replica,
                    op,
                    checksum,
                });

                self.journal.read_prepare(repair_pipeline_push, op, checksum, null);
            } else {
                log.debug("{}: primary_repair_pipeline_read: repaired", .{self.replica});
                self.repairing_pipeline = false;
                self.repair();
            }
        }

        fn repair_pipeline_push(
            self: *Self,
            prepare: ?*Message,
            destination_replica: ?u8,
        ) void {
            assert(destination_replica == null);

            assert(self.repairing_pipeline);
            self.repairing_pipeline = false;

            if (prepare == null) {
                log.debug("{}: repair_pipeline_push: prepare == null", .{self.replica});
                return;
            }

            // Our state may have advanced significantly while we were reading from disk.
            if (self.status != .view_change) {
                log.debug("{}: repair_pipeline_push: no longer in view change status", .{
                    self.replica,
                });
                return;
            }

            if (self.primary_index(self.view) != self.replica) {
                log.debug("{}: repair_pipeline_push: no longer primary", .{self.replica});
                return;
            }

            // We may even be several views ahead and may now have a completely different pipeline.
            const op = self.primary_repair_pipeline_op() orelse {
                log.debug("{}: repair_pipeline_push: pipeline changed", .{self.replica});
                return;
            };

            assert(op > self.commit_max);
            assert(op <= self.op);
            assert(self.commit_max + self.pipeline.count + 1 == op);

            if (prepare.?.header.op != op) {
                log.debug("{}: repair_pipeline_push: op changed", .{self.replica});
                return;
            }

            if (prepare.?.header.checksum != self.journal.header_with_op(op).?.checksum) {
                log.debug("{}: repair_pipeline_push: checksum changed", .{self.replica});
                return;
            }

            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);

            log.debug("{}: repair_pipeline_push: op={} checksum={}", .{
                self.replica,
                prepare.?.header.op,
                prepare.?.header.checksum,
            });

            if (self.pipeline.tail_ptr()) |parent| {
                assert(prepare.?.header.parent == parent.message.header.checksum);
            }

            self.pipeline.push_assume_capacity(.{ .message = prepare.?.ref() });
            assert(self.pipeline.count >= 1);

            self.repairing_pipeline = true;
            self.primary_repair_pipeline_read();
        }

        fn repair_prepares(self: *Self) void {
            assert(self.status == .normal or self.status == .view_change);
            assert(self.repairs_allowed());
            assert(self.journal.dirty.count > 0);
            assert(self.op >= self.commit_min);
            assert(self.op - self.commit_min + 1 <= constants.journal_slot_count);

            // Request enough prepares to utilize our max IO depth:
            var budget = self.journal.writes.available();
            if (budget == 0) {
                log.debug("{}: repair_prepares: waiting for IOP", .{self.replica});
                return;
            }

            if (self.op < constants.journal_slot_count) {
                // The op is known, and this is the first WAL cycle.
                // Therefore, any faulty ops to the right of `replica.op` are corrupt reserved
                // entries from the initial format, or corrupt prepares which were since truncated.
                var op: usize = self.op + 1;
                while (op < constants.journal_slot_count) : (op += 1) {
                    const slot = self.journal.slot_for_op(op);
                    assert(slot.index == op);

                    if (self.journal.faulty.bit(slot)) {
                        assert(self.journal.headers[op].command == .reserved);
                        assert(self.journal.headers_redundant[op].command == .reserved);
                        self.journal.dirty.clear(slot);
                        self.journal.faulty.clear(slot);
                        log.debug("{}: repair_prepares: remove slot={} " ++
                            "(faulty, op known, first cycle)", .{
                            self.replica,
                            slot.index,
                        });
                    }
                }
            }

            var op = self.op + 1;
            // To maximize durability, repair all prepares for which we have a header (not only
            // uncommitted headers). This in turn enables the replica to help repair other replicas.
            const op_min = op -| constants.journal_slot_count;
            while (op > op_min) {
                op -= 1;

                const slot = self.journal.slot_for_op(op);
                if (self.journal.dirty.bit(slot)) {
                    if (self.journal.slot_with_op(op) == null) {
                        // If this op was between `commit_min` and `replica.op`, we would have
                        // requested and repaired these headers.
                        // If this op was between `op_checkpoint` and `commit_min`, we would have
                        // a header (since we couldn't have committed otherwise).
                        //
                        // Therefore, this op must be either:
                        // - less-than-or-equal-to `op_checkpoint` — we committed before
                        //   checkpointing, but the entry in our WAL was found corrupt after
                        //   recovering from a crash.
                        // - or (indistinguishably) this might originally have been an op greater
                        //   than replica.op, which was truncated, but is now corrupt.
                        //
                        // We don't try to repair this op because the slot belongs (or will soon
                        // belong) to a newer op, from the new WAL wrap. Additionally, we may not
                        // still have access to its surrounding commits to verify the hash chain.
                        assert(op <= self.commit_min);
                        assert(op <= self.op_checkpoint);
                        assert(self.journal.faulty.bit(slot));

                        log.debug("{}: repair_prepares: remove slot={} " ++
                            "(faulty, precedes checkpoint)", .{
                            self.replica,
                            slot.index,
                        });
                        self.journal.remove_entry(slot);
                        continue;
                    }

                    // If this is an uncommitted op, and we are the primary in `view_change` status,
                    // then we will `request_prepare` from the cluster, set `nack_prepare_op`,
                    // and stop repairing any further prepares:
                    // This will also rebroadcast any `request_prepare` every `repair_timeout` tick.
                    if (self.repair_prepare(op)) {
                        if (self.nack_prepare_op) |nack_prepare_op| {
                            assert(nack_prepare_op == op);
                            assert(self.status == .view_change);
                            assert(self.primary_index(self.view) == self.replica);
                            assert(op > self.commit_max);
                            return;
                        }

                        // Otherwise, we continue to request prepares until our budget is used:
                        budget -= 1;
                        if (budget == 0) {
                            log.debug("{}: repair_prepares: request budget used", .{self.replica});
                            return;
                        }
                    }
                } else {
                    assert(!self.journal.faulty.bit(slot));
                }
            }
        }

        /// During a view change, for uncommitted ops, which are few, we optimize for latency:
        ///
        /// * request a `prepare` or `nack_prepare` from all backups in parallel,
        /// * repair as soon as we get a `prepare`, or
        /// * discard as soon as we get a majority of `nack_prepare` messages for the same checksum.
        ///
        /// For committed ops, which represent the bulk of ops, we optimize for throughput:
        ///
        /// * have multiple requests in flight to prime the repair queue,
        /// * rotate these requests across the cluster round-robin,
        /// * to spread the load across connected peers,
        /// * to take advantage of each peer's outgoing bandwidth, and
        /// * to parallelize disk seeks and disk read bandwidth.
        ///
        /// This is effectively "many-to-one" repair, where a single replica recovers using the
        /// resources of many replicas, for faster recovery.
        fn repair_prepare(self: *Self, op: u64) bool {
            const slot = self.journal.slot_with_op(op).?;
            const checksum = self.journal.header_with_op(op).?.checksum;

            assert(self.status == .normal or self.status == .view_change);
            assert(self.repairs_allowed());
            assert(self.journal.dirty.bit(slot));

            // We may be appending to or repairing the journal concurrently.
            // We do not want to re-request any of these prepares unnecessarily.
            if (self.journal.writing(op, checksum)) {
                log.debug("{}: repair_prepare: op={} checksum={} (already writing)", .{
                    self.replica,
                    op,
                    checksum,
                });
                return false;
            }

            // The message may be available in the local pipeline.
            // For example (replica_count=3):
            // 1. View=1: Replica 1 is primary, and prepares op 5. The local write fails.
            // 2. Time passes. The view changes (e.g. due to a timeout)…
            // 3. View=4: Replica 1 is primary again, and is repairing op 5
            //    (which is still in the pipeline).
            //
            // Using the pipeline to repair is faster than a `request_prepare`.
            // Also, messages in the pipeline are never corrupt.
            if (self.pipeline_prepare_for_op_and_checksum(op, checksum)) |prepare| {
                assert(prepare.message.header.op == op);
                assert(prepare.message.header.checksum == checksum);

                if (self.replica_count == 1) {
                    // This op won't start writing until all ops in the pipeline preceding it have
                    // been written.
                    log.debug("{}: repair_prepare: op={} checksum={} (serializing append)", .{
                        self.replica,
                        op,
                        checksum,
                    });
                    assert(op > self.pipeline.head_ptr().?.message.header.op);
                    return false;
                }

                log.debug("{}: repair_prepare: op={} checksum={} (from pipeline)", .{
                    self.replica,
                    op,
                    checksum,
                });
                self.write_prepare(prepare.message, .pipeline);
                return true;
            }

            const request_prepare = Header{
                .command = .request_prepare,
                // If we request a prepare from a backup, as below, it is critical to pass a
                // checksum: Otherwise we could receive different prepares for the same op number.
                .context = checksum,
                .timestamp = 1, // The checksum is included in context.
                .cluster = self.cluster,
                .replica = self.replica,
                .view = self.view,
                .op = op,
            };

            if (self.status == .view_change and op > self.commit_max) {
                // Only the primary is allowed to do repairs in a view change:
                assert(self.primary_index(self.view) == self.replica);

                const reason = if (self.journal.faulty.bit(slot)) "faulty" else "dirty";
                log.debug(
                    "{}: repair_prepare: op={} checksum={} (uncommitted, {s}, view_change)",
                    .{
                        self.replica,
                        op,
                        checksum,
                        reason,
                    },
                );

                if (self.replica_count == 2 and !self.journal.faulty.bit(slot)) {
                    // This is required to avoid a liveness issue for a cluster-of-two where a new
                    // primary learns of an op during a view change but where the op is faulty on
                    // the old primary. We must immediately roll back the op since it could not have
                    // been committed by the old primary if we know we do not have it, and because
                    // the old primary cannot send a nack_prepare for its faulty copy.
                    // For this to be correct, the recovery protocol must set all headers as faulty,
                    // not only as dirty.
                    self.primary_discard_uncommitted_ops_from(op, checksum);
                    return false;
                }

                // Initialize the `nack_prepare` quorum counter for this uncommitted op:
                // It is also possible that we may start repairing a lower uncommitted op, having
                // initialized `nack_prepare_op` before we learn of a higher uncommitted dirty op,
                // in which case we also want to reset the quorum counter.
                if (self.nack_prepare_op) |nack_prepare_op| {
                    assert(nack_prepare_op <= op);
                    if (nack_prepare_op != op) {
                        self.nack_prepare_op = op;
                        self.reset_quorum_counter(&self.nack_prepare_from_other_replicas);
                    }
                } else {
                    self.nack_prepare_op = op;
                    self.reset_quorum_counter(&self.nack_prepare_from_other_replicas);
                }

                assert(self.nack_prepare_op.? == op);
                assert(request_prepare.context == checksum);
                self.send_header_to_other_replicas(request_prepare);
            } else {
                const nature = if (op > self.commit_max) "uncommitted" else "committed";
                const reason = if (self.journal.faulty.bit(slot)) "faulty" else "dirty";
                log.debug("{}: repair_prepare: op={} checksum={} ({s}, {s})", .{
                    self.replica,
                    op,
                    checksum,
                    nature,
                    reason,
                });

                // We expect that `repair_prepare()` is called in reverse chronological order:
                // Any uncommitted ops should have already been dealt with.
                // We never roll back committed ops, and thus never regard `nack_prepare` responses.
                // Alternatively, we may not be the primary, in which case we do distinguish anyway.
                assert(self.nack_prepare_op == null);
                assert(request_prepare.context == checksum);
                if (self.choose_any_other_replica()) |replica| {
                    self.send_header_to_replica(replica, request_prepare);
                }
            }

            return true;
        }

        fn repairs_allowed(self: *Self) bool {
            switch (self.status) {
                .view_change => {
                    if (self.do_view_change_quorum) {
                        assert(self.primary_index(self.view) == self.replica);
                        return true;
                    } else {
                        return false;
                    }
                },
                .normal => return true,
                else => return false,
            }
        }

        /// The caller must ensure that the headers are trustworthy.
        ///
        /// Asserts that sequential ops are hash-chained. (Gaps are permitted).
        fn replace_headers(self: *Self, headers: []const Header) void {
            for (headers) |*header, i| {
                if (i > 0) {
                    const next = &headers[i - 1];
                    assert(next.view >= header.view);
                    if (next.op == header.op + 1) {
                        assert(next.parent == header.checksum);
                    } else {
                        assert(next.op > header.op);
                    }
                }

                self.replace_header(header);
            }
        }

        /// Replaces the header if the header is different and not already committed.
        /// The caller must ensure that the header is trustworthy.
        fn replace_header(self: *Self, header: *const Header) void {
            assert(self.op_checkpoint <= self.commit_min);
            assert(header.command == .prepare);
            assert(header.op <= self.op); // Never advance the op.
            assert(header.op <= self.op_checkpoint_trigger());

            if (header.op <= self.commit_min) {
                if (self.journal.header_with_op(header.op)) |existing_header| {
                    assert(existing_header.checksum == header.checksum);
                    return;
                } else {
                    if (header.op <= self.op_checkpoint) {
                        // Never replace a checkpointed op — those slots are needed by the following
                        // WAL wrap.
                        return;
                    } else {
                        // If an op is committed but not checkpointed, we must still have the header.
                        @panic("missing committed, uncheckpointed header");
                    }
                }
            }

            // Do not set an op as dirty if we already have it exactly because:
            // 1. this would trigger a repair and delay the view change, or worse,
            // 2. prevent repairs to another replica when we have the op.
            if (!self.journal.has(header)) self.journal.set_header_as_dirty(header);
        }

        /// Replicates to the next replica in the configuration (until we get back to the primary):
        /// Replication starts and ends with the primary, we never forward back to the primary.
        /// Does not flood the network with prepares that have already committed.
        /// TODO Use recent heartbeat data for next replica to leapfrog if faulty (optimization).
        fn replicate(self: *Self, message: *Message) void {
            assert(self.status == .normal);
            assert(message.header.command == .prepare);
            assert(message.header.view == self.view);
            assert(message.header.op == self.op);

            if (message.header.op <= self.commit_max) {
                log.debug("{}: replicate: not replicating (committed)", .{self.replica});
                return;
            }

            const next = @mod(self.replica + 1, @intCast(u8, self.replica_count));
            if (next == self.primary_index(message.header.view)) {
                log.debug("{}: replicate: not replicating (completed)", .{self.replica});
                return;
            }

            log.debug("{}: replicate: replicating to replica {}", .{ self.replica, next });
            self.send_message_to_replica(next, message);
        }

        fn reset_quorum_messages(self: *Self, messages: *QuorumMessages, command: Command) void {
            assert(messages.len == constants.replicas_max);
            var view: ?u32 = null;
            var count: usize = 0;
            for (messages) |*received, replica| {
                if (received.*) |message| {
                    assert(replica < self.replica_count);
                    assert(message.header.command == command);
                    assert(message.header.replica == replica);
                    // We may have transitioned into a newer view:
                    // However, all messages in the quorum should have the same view.
                    assert(message.header.view <= self.view);
                    if (view) |v| {
                        assert(message.header.view == v);
                    } else {
                        view = message.header.view;
                    }

                    self.message_bus.unref(message);
                    count += 1;
                }
                received.* = null;
            }
            assert(count <= self.replica_count);
            log.debug("{}: reset {} {s} message(s) from view={}", .{
                self.replica,
                count,
                @tagName(command),
                view,
            });
        }

        fn reset_quorum_counter(self: *Self, counter: *QuorumCounter) void {
            var counter_iterator = counter.iterator(.{});
            while (counter_iterator.next()) |replica| {
                assert(replica < self.replica_count);
            }

            counter.* = quorum_counter_null;
            assert(counter.count() == 0);

            var replica: usize = 0;
            while (replica < self.replica_count) : (replica += 1) {
                assert(!counter.isSet(replica));
            }
        }

        fn reset_quorum_do_view_change(self: *Self) void {
            self.reset_quorum_messages(&self.do_view_change_from_all_replicas, .do_view_change);
            self.do_view_change_quorum = false;
        }

        fn reset_quorum_nack_prepare(self: *Self) void {
            self.reset_quorum_counter(&self.nack_prepare_from_other_replicas);
            self.nack_prepare_op = null;
        }

        fn reset_quorum_prepare_ok(self: *Self) void {
            // "prepare_ok"s from previous views are not valid, even if the pipeline entry is reused
            // after a cycle of view changes. In other words, when a view change cycles around, so
            // that the original primary becomes a primary of a new view, pipeline entries may be
            // reused. However, the pipeline's prepare_ok quorums must not be reused, since the
            // replicas that sent them may have swapped them out during a previous view change.
            var iterator = self.pipeline.iterator_mutable();
            while (iterator.next_ptr()) |prepare| {
                prepare.ok_quorum_received = false;
                prepare.ok_from_all_replicas = quorum_counter_null;
                assert(prepare.ok_from_all_replicas.count() == 0);
            }
        }

        fn reset_quorum_start_view_change(self: *Self) void {
            self.reset_quorum_counter(&self.start_view_change_from_other_replicas);
            self.start_view_change_quorum = false;
        }

        fn reset_quorum_recovery_response(self: *Self) void {
            for (self.recovery_response_from_other_replicas) |*received, replica| {
                if (received.*) |message| {
                    assert(replica != self.replica);
                    self.message_bus.unref(message);
                    received.* = null;
                }
            }
        }

        fn send_prepare_ok(self: *Self, header: *const Header) void {
            assert(header.command == .prepare);
            assert(header.cluster == self.cluster);
            assert(header.replica == self.primary_index(header.view));
            assert(header.view <= self.view);
            assert(header.op <= self.op or header.view < self.view);

            if (self.status != .normal) {
                log.debug("{}: send_prepare_ok: not sending ({})", .{ self.replica, self.status });
                return;
            }

            if (header.op > self.op) {
                assert(header.view < self.view);
                // An op may be reordered concurrently through a view change while being journalled:
                log.debug("{}: send_prepare_ok: not sending (reordered)", .{self.replica});
                return;
            }

            assert(self.status == .normal);
            // After a view change, replicas send prepare_oks for uncommitted ops with older views:
            // However, we only send to the primary of the current view (see below where we send).
            assert(header.view <= self.view);
            assert(header.op <= self.op);

            if (header.op <= self.commit_max) {
                log.debug("{}: send_prepare_ok: not sending (committed)", .{self.replica});
                return;
            }

            if (self.journal.has_clean(header)) {
                log.debug("{}: send_prepare_ok: op={} checksum={}", .{
                    self.replica,
                    header.op,
                    header.checksum,
                });

                // It is crucial that replicas stop accepting prepare messages from earlier views
                // once they start the view change protocol. Without this constraint, the system
                // could get into a state in which there are two active primaries: the old one,
                // which hasn't failed but is merely slow or not well connected to the network, and
                // the new one. If a replica sent a prepare_ok message to the old primary after
                // sending its log to the new one, the old primary might commit an operation that
                // the new primary doesn't learn about in the do_view_change messages.

                // We therefore only ever send to the primary of the current view, never to the
                // primary of the prepare header's view:
                self.send_header_to_replica(self.primary_index(self.view), .{
                    .command = .prepare_ok,
                    .parent = header.parent,
                    .client = header.client,
                    .context = header.checksum,
                    .request = header.request,
                    .cluster = self.cluster,
                    .replica = self.replica,
                    .epoch = header.epoch,
                    .view = self.view,
                    .op = header.op,
                    .commit = header.commit,
                    .timestamp = header.timestamp,
                    .operation = header.operation,
                });
            } else {
                log.debug("{}: send_prepare_ok: not sending (dirty)", .{self.replica});
                return;
            }
        }

        fn send_prepare_oks_after_view_change(self: *Self) void {
            assert(self.status == .normal);

            var op = self.commit_max + 1;
            while (op <= self.op) : (op += 1) {
                // We may have breaks or stale headers in our uncommitted chain here. However:
                // * being able to send what we have will allow the pipeline to commit earlier, and
                // * the primary will drop any prepare_ok for a prepare not in the pipeline.
                // This is safe only because the primary can verify against the prepare checksum.
                if (self.journal.header_with_op(op)) |header| {
                    self.send_prepare_ok(header);
                    defer self.flush_loopback_queue();
                }
            }
        }

        fn send_start_view_change(self: *Self) void {
            assert(self.status == .view_change);
            assert(!self.do_view_change_quorum);
            // Send only to other replicas (and not to ourself) to avoid a quorum off-by-one error:
            // This could happen if the replica mistakenly counts its own message in the quorum.
            self.send_header_to_other_replicas(.{
                .command = .start_view_change,
                .cluster = self.cluster,
                .replica = self.replica,
                .view = self.view,
            });
        }

        fn send_do_view_change(self: *Self) void {
            assert(self.status == .view_change);
            assert(self.start_view_change_quorum);
            assert(!self.do_view_change_quorum);

            const count_start_view_change = self.start_view_change_from_other_replicas.count();
            assert(count_start_view_change >= self.quorum_view_change - 1);
            assert(count_start_view_change <= self.replica_count - 1);

            const message = self.create_view_change_message(.do_view_change);
            defer self.message_bus.unref(message);

            assert(message.references == 1);
            assert(message.header.command == .do_view_change);
            assert(message.header.view == self.view);
            assert(message.header.op == self.op);
            assert(message.header.op == message_body_as_headers(message)[0].op);
            // Each replica must advertise its own commit number, so that the new primary can know
            // which headers must be replaced in its log. Otherwise, a gap in the log may prevent
            // the new primary from repairing its log, resulting in the log being forked if the new
            // primary also discards uncommitted operations.
            // It is also safe not to use `commit_max` here because the new primary will assume that
            // operations after the highest `commit_min` may yet have been committed before the old
            // primary crashed. The new primary will use the NACK protocol to be sure of a discard.
            assert(message.header.commit == self.commit_min);

            self.send_message_to_replica(self.primary_index(self.view), message);
        }

        fn send_eviction_message_to_client(self: *Self, client: u128) void {
            assert(self.status == .normal);
            assert(self.primary());

            log.err("{}: too many sessions, sending eviction message to client={}", .{
                self.replica,
                client,
            });

            self.send_header_to_client(client, .{
                .command = .eviction,
                .cluster = self.cluster,
                .replica = self.replica,
                .view = self.view,
                .client = client,
            });
        }

        fn send_header_to_client(self: *Self, client: u128, header: Header) void {
            const message = self.create_message_from_header(header);
            defer self.message_bus.unref(message);

            self.message_bus.send_message_to_client(client, message);
        }

        fn send_header_to_other_replicas(self: *Self, header: Header) void {
            const message = self.create_message_from_header(header);
            defer self.message_bus.unref(message);

            var replica: u8 = 0;
            while (replica < self.replica_count) : (replica += 1) {
                if (replica != self.replica) {
                    self.send_message_to_replica(replica, message);
                }
            }
        }

        fn send_header_to_replica(self: *Self, replica: u8, header: Header) void {
            const message = self.create_message_from_header(header);
            defer self.message_bus.unref(message);

            self.send_message_to_replica(replica, message);
        }

        fn send_message_to_other_replicas(self: *Self, message: *Message) void {
            var replica: u8 = 0;
            while (replica < self.replica_count) : (replica += 1) {
                if (replica != self.replica) {
                    self.send_message_to_replica(replica, message);
                }
            }
        }

        fn send_message_to_replica(self: *Self, replica: u8, message: *Message) void {
            log.debug("{}: sending {s} to replica {}: {}", .{
                self.replica,
                @tagName(message.header.command),
                replica,
                message.header,
            });

            if (message.header.invalid()) |reason| {
                log.err("{}: send_message_to_replica: invalid ({s})", .{ self.replica, reason });
                @panic("send_message_to_replica: invalid message");
            }

            assert(message.header.cluster == self.cluster);

            // TODO According to message.header.command, assert on the destination replica.
            switch (message.header.command) {
                .reserved => unreachable,
                .request => {
                    // Do not assert message.header.replica because we forward .request messages.
                    assert(self.status == .normal);
                    assert(message.header.view <= self.view);
                },
                .prepare => {
                    // Do not assert message.header.replica because we forward .prepare messages.
                    switch (self.status) {
                        .normal => assert(message.header.view <= self.view),
                        .view_change => assert(message.header.view < self.view),
                        else => unreachable,
                    }
                },
                .prepare_ok => {
                    assert(self.status == .normal);
                    assert(message.header.view == self.view);
                    assert(message.header.op <= self.op_checkpoint_trigger());
                    // We must only ever send a prepare_ok to the latest primary of the active view:
                    // We must never straddle views by sending to a primary in an older view.
                    // Otherwise, we would be enabling a partitioned primary to commit.
                    assert(replica == self.primary_index(self.view));
                    assert(message.header.replica == self.replica);
                },
                .start_view_change => {
                    assert(self.status == .view_change);
                    assert(message.header.view == self.view);
                    assert(message.header.replica == self.replica);
                },
                .do_view_change => {
                    assert(self.status == .view_change);
                    assert(self.start_view_change_quorum);
                    assert(!self.do_view_change_quorum);
                    assert(message.header.view == self.view);
                    assert(message.header.replica == self.replica);
                    assert(message.header.op == self.op);
                    assert(message.header.commit == self.commit_min);
                    assert(replica == self.primary_index(self.view));
                },
                .start_view => switch (self.status) {
                    .normal => {
                        // A backup may ask the primary to resend the start_view message.
                        assert(!self.start_view_change_quorum);
                        assert(!self.do_view_change_quorum);
                        assert(message.header.view == self.view);
                        assert(message.header.replica == self.replica);
                        assert(message.header.replica != replica);
                    },
                    .view_change => {
                        assert(self.start_view_change_quorum);
                        assert(self.do_view_change_quorum);
                        assert(message.header.view == self.view);
                        assert(message.header.replica == self.replica);
                        assert(message.header.replica != replica);
                    },
                    else => unreachable,
                },
                .recovery => {
                    assert(self.status == .recovering);
                    assert(message.header.replica == self.replica);
                    assert(message.header.replica != replica);
                    assert(message.header.context == self.recovery_nonce);
                },
                .recovery_response => {
                    assert(self.status == .normal);
                    assert(message.header.view == self.view);
                    assert(message.header.replica == self.replica);
                    assert(message.header.replica != replica);
                },
                .headers => {
                    assert(self.status == .normal or self.status == .view_change);
                    assert(message.header.view == self.view);
                    assert(message.header.replica == self.replica);
                    assert(message.header.replica != replica);
                },
                .ping, .pong => {
                    assert(message.header.view == self.view);
                    assert(message.header.replica == self.replica);
                    assert(message.header.replica != replica);
                },
                .commit => {
                    assert(self.status == .normal);
                    assert(self.primary());
                    assert(message.header.view == self.view);
                    assert(message.header.replica == self.replica);
                    assert(message.header.replica != replica);
                },
                .request_start_view => {
                    assert(message.header.view >= self.view);
                    assert(message.header.replica == self.replica);
                    assert(message.header.replica != replica);
                    assert(self.primary_index(message.header.view) == replica);
                },
                .request_headers => {
                    assert(message.header.view == self.view);
                    assert(message.header.replica == self.replica);
                    assert(message.header.replica != replica);
                },
                .request_prepare => {
                    assert(message.header.view == self.view);
                    assert(message.header.replica == self.replica);
                    assert(message.header.replica != replica);
                },
                .nack_prepare => {
                    assert(message.header.view == self.view);
                    assert(message.header.replica == self.replica);
                    assert(message.header.replica != replica);
                    assert(self.primary_index(self.view) == replica);
                },
                else => {
                    log.info("{}: send_message_to_replica: TODO {s}", .{
                        self.replica,
                        @tagName(message.header.command),
                    });
                },
            }

            if (replica == self.replica) {
                assert(self.loopback_queue == null);
                self.loopback_queue = message.ref();
            } else {
                self.message_bus.send_message_to_replica(replica, message);
            }
        }

        fn set_op_and_commit_max(self: *Self, op: u64, commit_max: u64, method: []const u8) void {
            assert(self.status == .view_change or self.status == .recovering);

            switch (self.status) {
                .normal => unreachable,
                .view_change => {},
                .recovering => {
                    // The replica's view hasn't been set yet.
                    // It will be set shortly, when we transition to normal status.
                    assert(self.view == 0);
                },
            }

            // Uncommitted ops may not survive a view change so we must assert `op` against
            // `commit_max` and not `self.op`. However, committed ops (`commit_max`) must survive:
            assert(op >= self.commit_max);
            assert(op >= commit_max);
            // TODO: This assertion may fail until recovery protocol is removed.
            assert(op <= self.op_checkpoint_trigger());

            // We expect that our commit numbers may also be greater even than `commit_max` because
            // we may be the old primary joining towards the end of the view change and we may have
            // committed `op` already.
            // However, this is bounded by pipelining.
            // The intersection property only requires that all possibly committed operations must
            // survive into the new view so that they can then be committed by the new primary.
            // This guarantees that if the old primary possibly committed the operation, then the
            // new primary will also commit the operation.
            if (commit_max < self.commit_max and self.commit_min == self.commit_max) {
                log.debug("{}: {s}: k={} < commit_max={} and commit_min == commit_max", .{
                    self.replica,
                    method,
                    commit_max,
                    self.commit_max,
                });
            }

            assert(commit_max >=
                self.commit_max - std.math.min(constants.pipeline_max, self.commit_max));

            assert(self.commit_min <= self.commit_max);
            assert(self.op >= self.commit_max or self.op < self.commit_max);

            const previous_op = self.op;
            const previous_commit_max = self.commit_max;

            self.op = op;
            self.journal.remove_entries_from(self.op + 1);

            // Crucially, we must never rewind `commit_max` (and then `commit_min`) because
            // `commit_min` represents what we have already applied to our state machine:
            self.commit_max = std.math.max(self.commit_max, commit_max);

            assert(self.commit_min <= self.commit_max);
            assert(self.commit_max <= self.op);

            log.debug("{}: {s}: view={} op={}..{} commit={}..{}", .{
                self.replica,
                method,
                self.view,
                previous_op,
                self.op,
                previous_commit_max,
                self.commit_max,
            });
        }

        /// Load the new view's headers from the DVC quorum.
        ///
        /// The iteration order of DVCs for repair does not impact the final result.
        /// In other words, you can't end up in a situation with a DVC quorum like:
        ///
        ///   replica     headers  commit_min
        ///         0   4 5 _ _ 8           4 (new primary; handling DVC quorum)
        ///         1   4 _ 6 _ 8           4
        ///         2   4 _ _ 7 8           4
        ///         3  (4 5 6 7 8)          8 (didn't participate in view change)
        ///         4  (4 5 6 7 8)          8 (didn't participate in view change)
        ///
        /// where the new primary's headers depends on which of replica 1 and 2's DVC is used
        /// for repair before the other (i.e. whether they repair op 6 or 7 first).
        ///
        /// For the above case to occur, replicas 0, 1, and 2 must all share the highest `view_normal`.
        /// And since they share the latest `view_normal`, ops 5,6,7 were just installed by
        /// `replace_header`, which is order-independent (it doesn't use the hash chain).
        ///
        /// (If replica 0's view_normal was greater than 1/2's, then replica 0 must have all
        /// headers from previous views. Which means 6,7 are from the current view. But since
        /// replica 0 doesn't have 6/7, then replica 1/2 must share the latest view_normal. ∎)
        fn primary_set_log_from_do_view_change_messages(self: *Self) void {
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);
            assert(self.replica_count > 1);
            assert(self.start_view_change_quorum);
            assert(self.do_view_change_quorum);

            const do_view_change_head = self.do_view_change_quorum_head();
            assert(do_view_change_head.view_normal >= self.view_normal);
            assert(do_view_change_head.op >= self.commit_min);
            assert(do_view_change_head.op >= do_view_change_head.commit_min_max);
            assert(do_view_change_head.commit_min_max >= self.commit_min);

            // The `prepare_timestamp` prevents a primary's own clock from running backwards.
            // Therefore, `prepare_timestamp`:
            // 1. is advanced if behind the cluster, but never reset if ahead of the cluster, i.e.
            // 2. may not always reflect the timestamp of the latest prepared op, and
            // 3. should be advanced before discarding the timestamps of any uncommitted headers.
            if (self.state_machine.prepare_timestamp < do_view_change_head.timestamp) {
                self.state_machine.prepare_timestamp = do_view_change_head.timestamp;
            }

            const view_normal_canonical = do_view_change_head.view_normal;
            // `op_canonical` must be computed before calling `set_op_and_commit_max()`, since
            // that may change `replica.op`.
            //
            // Don't remove the uncanonical headers yet — even though the removed headers are
            // a subset of the DVC headers, removing and then adding them back would cause clean
            // headers to become dirty.
            const op_canonical = self.primary_op_canonical_max(view_normal_canonical);
            assert(op_canonical <= self.op);
            assert(op_canonical >= self.op -| constants.pipeline_max);
            assert(op_canonical >= self.commit_min);

            if (do_view_change_head.op > self.op_checkpoint_trigger()) {
                // This replica is too far behind, i.e. the new `self.op` is too far ahead of the
                // last checkpoint. If we wrap now, we overwrite un-checkpointed transfers in the WAL,
                // precluding recovery.
                //
                // TODO State transfer. Currently this is unreachable because the
                // primary won't checkpoint until all replicas are caught up.
                unreachable;
            }

            self.set_op_and_commit_max(
                do_view_change_head.op,
                // `set_op_and_commit_max()` expects the highest commit_max that we know of.
                // But DVCs include replica's `commit_min`, not `commit_max`.
                std.math.max(
                    self.commit_max,
                    do_view_change_head.commit_min_max,
                ),
                "on_do_view_change",
            );
            // "`replica.op` exists" invariant may be broken until after the canonical DVC headers
            // are installed.

            // First, set all the canonical headers from the replica(s) with highest `view_normal`:
            for (self.do_view_change_from_all_replicas) |received| {
                if (received) |message| {
                    const view_normal = @intCast(u32, message.header.timestamp);
                    // The view in which this replica's status was normal must be before this view.
                    assert(view_normal < message.header.view);

                    if (view_normal < view_normal_canonical) continue;
                    assert(view_normal == view_normal_canonical);

                    const message_headers = message_body_as_headers(message);
                    for (message_headers) |*header| {
                        log.debug(
                            "{}: on_do_view_change: canonical: replica={} op={} checksum={}",
                            .{
                                self.replica,
                                message.header.replica,
                                header.op,
                                header.checksum,
                            },
                        );
                    }
                    self.replace_headers(message_headers);
                }
            }

            // Since we used do_view_change_head to set the replica.op, it must have been loaded
            // into the headers (if it wasn't present already).
            assert(self.journal.header_with_op(self.op) != null);

            // Now that the canonical headers are all in place, repair any other headers:
            for (self.do_view_change_from_all_replicas) |received| {
                if (received) |message| {
                    const view_normal = @intCast(u32, message.header.timestamp);
                    assert(view_normal < message.header.view);

                    if (view_normal == view_normal_canonical) continue;
                    assert(view_normal < view_normal_canonical);

                    for (message_body_as_headers(message)) |*header| {
                        // We must trust headers that other replicas have committed, because
                        // repair_header() will not repair a header if the hash chain has a gap.
                        if (header.op <= message.header.commit) {
                            log.debug(
                                "{}: on_do_view_change: committed: replica={} op={} checksum={}",
                                .{
                                    self.replica,
                                    message.header.replica,
                                    header.op,
                                    header.checksum,
                                },
                            );
                            self.replace_header(header);
                        } else {
                            _ = self.repair_header(header);
                        }
                    }
                }
            }

            const op_max = self.do_view_change_op_max(op_canonical);
            assert(op_max <= self.op);
            assert(op_max >= self.commit_min);
            if (op_max != self.op) {
                log.debug("{}: primary_set_log_from_do_view_change_messages: discard op={}..{}", .{
                    self.replica,
                    op_max + 1,
                    self.op,
                });
                self.journal.remove_entries_from(op_max + 1);
                self.op = op_max;
            }
            assert(self.journal.header_with_op(self.op) != null);
        }

        fn do_view_change_quorum_head(self: *const Self) struct {
            /// The highest `view_normal` of any DVC.
            ///
            /// The headers bundled with DVCs with the highest `view_normal` are canonical, since
            /// the replica has knowledge of previous view changes in which headers were replaced.
            view_normal: u32,
            /// The highest `commit_min` from any DVC (this is not a `commit_max`).
            commit_min_max: u64,
            /// The highest `op` from a DVC with the highest `view_normal`.
            op: u64,
            /// The higest timestamp from any DVC.
            timestamp: u64,
        } {
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);
            assert(self.replica_count > 1);
            assert(self.start_view_change_quorum);
            assert(self.do_view_change_quorum);
            assert(self.do_view_change_from_all_replicas[self.replica] != null);

            var v: ?u32 = null; // The highest `view_normal` from any replica.
            var n: ?u64 = null; // The highest `op` for the highest `view_normal` from any replica.
            var k: ?u64 = null; // The highest `commit_min` from any replica.
            var t: ?u64 = null; // The highest `timestamp` from any replica.

            for (self.do_view_change_from_all_replicas) |received, replica| {
                if (received) |message| {
                    assert(message.header.command == .do_view_change);
                    assert(message.header.cluster == self.cluster);
                    assert(message.header.replica == replica);
                    assert(message.header.view == self.view);
                    assert(message.header.op >= message.header.commit);
                    assert(message.header.op - message.header.commit <= constants.journal_slot_count);

                    // The view when this replica was last in normal status, which:
                    // * may be higher than the view in any of the prepare headers.
                    // * must be lower than the view of this view change.
                    const view_normal = @intCast(u32, message.header.timestamp);
                    assert(view_normal < message.header.view);

                    if (replica == self.replica) {
                        assert(view_normal == self.view_normal);
                        assert(message.header.op == self.op);
                        // We may have a newer commit than our DVC due to async commits (see below).
                        assert(message.header.commit <= self.commit_min);
                    }

                    log.debug(
                        "{}: on_do_view_change: " ++
                            "replica={} view_normal={} op={} commit_min={}",
                        .{
                            self.replica,
                            message.header.replica,
                            view_normal,
                            message.header.op,
                            message.header.commit, // The `commit_min` of the replica.
                        },
                    );

                    if (v == null or view_normal > v.?) {
                        v = view_normal;
                        n = message.header.op;
                    } else if (view_normal == v.? and message.header.op > n.?) {
                        n = message.header.op;
                    }

                    if (k == null or message.header.commit > k.?) k = message.header.commit;

                    const message_headers = message_body_as_headers(message);
                    if (t == null or t.? < message_headers[0].timestamp) {
                        t = message_headers[0].timestamp;
                    }
                }
            }

            // Consider the case:
            // 1. Start committing op=N…M.
            // 2. Send `do_view_change` to self.
            // 3. Finish committing op=N…M.
            // 4. Remaining `do_view_change` messages arrive, completing the quorum.
            // In this scenario, our own DVC's commit is `N-1`, but `commit_min=M`.
            // Don't let the commit backtrack.
            if (k.? < self.commit_min) {
                assert(self.commit_min >
                    self.do_view_change_from_all_replicas[self.replica].?.header.commit);
                log.debug("{}: on_do_view_change: bump commit_min view={} commit={}..{}", .{
                    self.replica,
                    self.view,
                    k.?,
                    self.commit_min,
                });
                k = self.commit_min;
            }

            assert(v.? >= self.view_normal);
            assert(k.? >= self.commit_min);

            return .{
                .view_normal = v.?,
                .commit_min_max = k.?,
                .op = n.?,
                .timestamp = t.?,
            };
        }

        /// Identify headers to discard during a view change before the primary starts the view.
        /// This is required to maximize availability in the presence of storage faults.
        /// Refer to the CTRL protocol from Protocol-Aware Recovery for Consensus-Based Storage.
        ///
        /// Returns the highest op that:
        /// - precedes any hash chain breaks in the uncanonical headers, and
        /// - precedes any gaps in the uncommitted headers.
        ///
        /// Breaks
        ///
        /// If there is a hash chain break, none of the headers from the canonical DVCs replaced
        /// the broken (leftover uncanonical) op.
        /// Removing these is necessary for correctness and liveness, to ensure that
        /// disconnected headers do not remain in place in lieu of gaps.
        ///
        /// Gaps
        ///
        /// It is possible for the new primary to have done an op jump in a previous view, and
        /// introduced a header gap for an op, which may have then been discarded by another primary
        /// during a view change, before surviving into this view as a gap because our latest op was
        /// set as the latest op for the quorum.
        ///
        /// In this case, it may be impossible for the new primary to repair the missing header as
        /// the rest of the cluster may have already discarded it. We therefore iterate over our
        /// uncommitted header gaps to discard any that may be impossible to repair.
        ///
        /// For example, if the old primary replicates ops=7,8,9 (all uncommitted) but only op=9 is
        /// prepared on another replica before the old primary crashes, then this function finds a
        /// gap for ops=7,8 and will attempt to discard ops 7,8,9.
        fn do_view_change_op_max(self: *const Self, op_canonical: u64) u64 {
            assert(self.replica_count > 1);
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);
            assert(self.do_view_change_quorum);
            assert(!self.repair_timeout.ticking);
            assert(self.op >= self.commit_max);
            // At least one replica in the new quorum committed in the new replica.op's WAL wrap —
            // wrapping implies a checkpoint (which implies a commit).
            assert(self.op - self.commit_max <= constants.journal_slot_count);
            assert(self.op - self.commit_min <= constants.journal_slot_count);

            assert(op_canonical <= self.op);
            assert(op_canonical >= self.commit_min);

            // Any uncanonical ops remaining either:
            // * Connect to the hash chain on the right.
            // * Do not connect on the right (hash chain break).
            //
            // If there is a hash chain break, none of the headers from the canonical DVCs replaced
            // the broken op. It is truncated like a gap.
            //
            // Removing these is necessary for correctness and liveness, to ensure that
            // disconnected headers do not remain in place in lieu of gaps.
            const op_before_break = blk: {
                var op: u64 = op_canonical;
                while (op < self.op) : (op += 1) {
                    if (self.journal.header_with_op(op)) |header| {
                        if (self.journal.header_with_op(op + 1)) |next| {
                            // Broken hash chain.
                            if (header.checksum != next.parent) break :blk op;
                        }
                    }
                } else break :blk self.op;
            };

            // Find the beginning of the lowest gap.
            //
            // While iterating > commit_max does not in itself guarantee that an op is uncommitted
            // (the old primary may have committed the op shortly before crashing), nevertheless,
            // if it was committed it would have survived into the new view as a header not a gap.
            const op_before_gap = blk: {
                // An op cannot be uncommitted if it is definitely outside the pipeline.
                const op_committed = std.math.max(self.commit_max, self.op -| constants.pipeline_max);
                assert(op_committed <= self.op);

                var op = op_committed;
                while (op < self.op) : (op += 1) {
                    if (self.journal.header_with_op(op + 1) == null) break :blk op;
                } else break :blk self.op;
            };

            return std.math.min(op_before_break, op_before_gap);
        }

        fn start_view_as_the_new_primary(self: *Self) void {
            assert(self.status == .view_change);
            assert(self.primary_index(self.view) == self.replica);
            assert(self.do_view_change_quorum);
            assert(!self.repairing_pipeline);

            assert(self.commit_min == self.commit_max);
            assert(self.primary_repair_pipeline_op() == null);
            self.verify_pipeline();
            assert(self.commit_max + self.pipeline.count == self.op);
            assert(self.valid_hash_chain_between(self.commit_min, self.op));

            assert(self.journal.dirty.count == 0);
            assert(self.journal.faulty.count == 0);
            assert(self.nack_prepare_op == null);

            const start_view = self.create_view_change_message(.start_view);
            defer self.message_bus.unref(start_view);

            self.transition_to_normal_from_view_change_status(self.view);
            // Detect if the transition to normal status above accidentally resets the pipeline:
            assert(self.commit_max + self.pipeline.count == self.op);

            assert(self.status == .normal);
            assert(self.primary());

            assert(start_view.references == 1);
            assert(start_view.header.command == .start_view);
            assert(start_view.header.view == self.view);
            assert(start_view.header.op == self.op);
            assert(start_view.header.commit == self.commit_max);

            // Send prepare_ok messages to ourself to contribute to the pipeline.
            self.send_prepare_oks_after_view_change();

            self.send_message_to_other_replicas(start_view);
        }

        fn transition_to_normal_from_recovering_status(self: *Self, new_view: u32) void {
            assert(self.status == .recovering);
            assert(self.view == 0);
            assert(!self.committing);
            assert(self.replica_count > 1 or new_view == 0);
            assert(self.journal.header_with_op(self.op) != null);
            self.view = new_view;
            self.view_normal = new_view;
            self.status = .normal;

            if (self.primary()) {
                log.debug(
                    "{}: transition_to_normal_from_recovering_status: view={} primary",
                    .{
                        self.replica,
                        self.view,
                    },
                );

                assert(self.journal.is_empty() or self.replica_count == 1);
                assert(!self.prepare_timeout.ticking);
                assert(!self.normal_status_timeout.ticking);
                assert(!self.view_change_status_timeout.ticking);
                assert(!self.view_change_message_timeout.ticking);

                self.ping_timeout.start();
                self.commit_timeout.start();
                self.repair_timeout.start();
                self.recovery_timeout.stop();
            } else {
                log.debug(
                    "{}: transition_to_normal_from_recovering_status: view={} backup",
                    .{
                        self.replica,
                        self.view,
                    },
                );

                assert(!self.prepare_timeout.ticking);
                assert(!self.commit_timeout.ticking);
                assert(!self.view_change_status_timeout.ticking);
                assert(!self.view_change_message_timeout.ticking);

                self.ping_timeout.start();
                self.normal_status_timeout.start();
                self.repair_timeout.start();
                self.recovery_timeout.stop();
            }
        }

        fn transition_to_normal_from_view_change_status(self: *Self, new_view: u32) void {
            // In the VRR paper it's possible to transition from normal to normal for the same view.
            // For example, this could happen after a state transfer triggered by an op jump.
            assert(self.status == .view_change);
            assert(new_view >= self.view);
            assert(self.journal.header_with_op(self.op) != null);
            self.view = new_view;
            self.view_normal = new_view;
            self.status = .normal;

            if (self.primary()) {
                log.debug(
                    "{}: transition_to_normal_from_view_change_status: view={} primary",
                    .{
                        self.replica,
                        self.view,
                    },
                );

                assert(!self.prepare_timeout.ticking);
                assert(!self.recovery_timeout.ticking);

                self.ping_timeout.start();
                self.commit_timeout.start();
                self.normal_status_timeout.stop();
                self.view_change_status_timeout.stop();
                self.view_change_message_timeout.stop();
                self.repair_timeout.start();

                // Do not reset the pipeline as there may be uncommitted ops to drive to completion.
                if (self.pipeline.count > 0) self.prepare_timeout.start();
            } else {
                log.debug("{}: transition_to_normal_from_view_change_status: view={} backup", .{
                    self.replica,
                    self.view,
                });

                assert(!self.prepare_timeout.ticking);
                assert(!self.recovery_timeout.ticking);

                self.ping_timeout.start();
                self.commit_timeout.stop();
                self.normal_status_timeout.start();
                self.view_change_status_timeout.stop();
                self.view_change_message_timeout.stop();
                self.repair_timeout.start();
            }

            self.reset_quorum_start_view_change();
            self.reset_quorum_do_view_change();
            self.reset_quorum_nack_prepare();
            self.reset_quorum_prepare_ok();

            assert(self.start_view_change_quorum == false);
            assert(self.do_view_change_quorum == false);
            assert(self.nack_prepare_op == null);
        }

        /// A replica i that notices the need for a view change advances its view, sets its status
        /// to view_change, and sends a ⟨start_view_change v, i⟩ message to all the other replicas,
        /// where v identifies the new view. A replica notices the need for a view change either
        /// based on its own timer, or because it receives a start_view_change or do_view_change
        /// message for a view with a larger number than its own view.
        fn transition_to_view_change_status(self: *Self, new_view: u32) void {
            log.debug("{}: transition_to_view_change_status: view={}..{}", .{
                self.replica,
                self.view,
                new_view,
            });
            assert(self.status == .normal or self.status == .view_change);
            assert(new_view > self.view);
            self.view = new_view;
            self.status = .view_change;

            self.ping_timeout.stop();
            self.commit_timeout.stop();
            self.normal_status_timeout.stop();
            self.view_change_status_timeout.start();
            self.view_change_message_timeout.start();
            self.repair_timeout.stop();
            self.prepare_timeout.stop();
            assert(!self.recovery_timeout.ticking);

            // Do not reset quorum counters only on entering a view, assuming that the view will be
            // followed only by a single subsequent view change to the next view, because multiple
            // successive view changes can fail, e.g. after a view change timeout.
            // We must therefore reset our counters here to avoid counting messages from an older
            // view, which would violate the quorum intersection property essential for correctness.
            self.reset_quorum_start_view_change();
            self.reset_quorum_do_view_change();
            self.reset_quorum_nack_prepare();
            self.reset_quorum_prepare_ok();

            assert(self.start_view_change_quorum == false);
            assert(self.do_view_change_quorum == false);
            assert(self.nack_prepare_op == null);

            self.send_start_view_change();
        }

        fn update_client_table_entry(self: *Self, reply: *Message) void {
            assert(reply.header.command == .reply);
            assert(reply.header.operation != .register);
            assert(reply.header.client > 0);
            assert(reply.header.context == 0);
            assert(reply.header.op == reply.header.commit);
            assert(reply.header.commit > 0);
            assert(reply.header.request > 0);

            if (self.client_table().get(reply.header.client)) |entry| {
                assert(entry.reply.header.command == .reply);
                assert(entry.reply.header.context == 0);
                assert(entry.reply.header.op == entry.reply.header.commit);
                assert(entry.reply.header.commit >= entry.session);

                assert(entry.reply.header.client == reply.header.client);
                assert(entry.reply.header.request + 1 == reply.header.request);
                assert(entry.reply.header.op < reply.header.op);
                assert(entry.reply.header.commit < reply.header.commit);

                // TODO Use this reply's prepare to cross-check against the entry's prepare, if we
                // still have access to the prepare in the journal (it may have been snapshotted).

                log.debug("{}: update_client_table_entry: client={} session={} request={}", .{
                    self.replica,
                    reply.header.client,
                    entry.session,
                    reply.header.request,
                });

                self.message_bus.unref(entry.reply);
                entry.reply = reply.ref();
            } else {
                // If no entry exists, then the session must have been evicted while being prepared.
                // We can still send the reply, the next request will receive an eviction message.
            }
        }

        /// Whether it is safe to commit or send prepare_ok messages.
        /// Returns true if the hash chain is valid and up to date for the current view.
        /// This is a stronger guarantee than `valid_hash_chain_between()` below.
        fn valid_hash_chain(self: *Self, method: []const u8) bool {
            // If we know we could validate the hash chain even further, then wait until we can:
            // This is partial defense-in-depth in case `self.op` is ever advanced by a reordered op.
            if (self.op < self.commit_max) {
                log.debug("{}: {s}: waiting for repair (op={} < commit={})", .{
                    self.replica,
                    method,
                    self.op,
                    self.commit_max,
                });
                return false;
            }

            // We must validate the hash chain as far as possible, since `self.op` may disclose a fork:
            if (!self.valid_hash_chain_between(self.commit_min, self.op)) {
                log.debug("{}: {s}: waiting for repair (hash chain)", .{ self.replica, method });
                return false;
            }

            return true;
        }

        /// Returns true if all operations are present, correctly ordered and connected by hash
        /// chain, between `op_min` and `op_max` (both inclusive).
        fn valid_hash_chain_between(self: *const Self, op_min: u64, op_max: u64) bool {
            assert(op_min <= op_max);
            // Headers with ops preceding the checkpoint may be unavailable due to a WAL wrap.
            assert(op_min >= self.op_checkpoint);

            // If we use anything less than self.op then we may commit ops for a forked hash chain
            // that have since been reordered by a new primary.
            assert(op_max == self.op);
            var b = self.journal.header_with_op(op_max).?;

            var op = op_max;
            while (op > op_min) {
                op -= 1;

                if (self.op_checkpoint == op) {
                    // op_checkpoint's slot may have been overwritten in the WAL — but we can
                    // always use the VSRState to anchor the hash chain.
                    assert(op == op_min);
                    assert(op == self.superblock.working.vsr_state.commit_min);
                    if (self.superblock.working.vsr_state.commit_min_checksum == b.parent) {
                        return true;
                    } else {
                        log.debug("{}: valid_hash_chain_between: break A: {} (checkpoint={})", .{
                            self.replica,
                            self.superblock.working.vsr_state.commit_min_checksum,
                            self.op_checkpoint,
                        });
                        log.debug("{}: valid_hash_chain_between: break B: {}", .{
                            self.replica,
                            b,
                        });
                        return false;
                    }
                }

                if (self.journal.header_with_op(op)) |a| {
                    assert(a.op + 1 == b.op);
                    if (a.checksum == b.parent) {
                        assert(ascending_viewstamps(a, b));
                        b = a;
                    } else {
                        log.debug("{}: valid_hash_chain_between: break: A: {}", .{ self.replica, a });
                        log.debug("{}: valid_hash_chain_between: break: B: {}", .{ self.replica, b });
                        return false;
                    }
                } else {
                    log.debug("{}: valid_hash_chain_between: missing op={}", .{ self.replica, op });
                    return false;
                }
            }
            assert(b.op == op_min);
            return true;
        }

        fn verify_pipeline(self: *Self) void {
            assert(self.status == .view_change);

            var op = self.commit_max + 1;
            var parent = self.journal.header_with_op(self.commit_max).?.checksum;

            var iterator = self.pipeline.iterator();
            while (iterator.next_ptr()) |prepare| {
                assert(prepare.message.header.command == .prepare);
                assert(!prepare.ok_quorum_received);
                assert(prepare.ok_from_all_replicas.count() == 0);

                log.debug("{}: verify_pipeline: op={} checksum={x} parent={x}", .{
                    self.replica,
                    prepare.message.header.op,
                    prepare.message.header.checksum,
                    prepare.message.header.parent,
                });

                assert(self.journal.has(prepare.message.header));
                assert(prepare.message.header.op == op);
                assert(prepare.message.header.op <= self.op);
                assert(prepare.message.header.parent == parent);

                parent = prepare.message.header.checksum;
                op += 1;
            }
            assert(self.pipeline.count <= constants.pipeline_max);
            assert(self.commit_max + self.pipeline.count == op - 1);
        }

        fn view_jump(self: *Self, header: *const Header) void {
            const to: Status = switch (header.command) {
                .prepare, .commit => .normal,
                .start_view_change, .do_view_change, .start_view => .view_change,
                else => unreachable,
            };

            if (self.status != .normal and self.status != .view_change) return;

            if (header.view < self.view) return;

            // Compare status transitions and decide whether to view jump or ignore:
            switch (self.status) {
                .normal => switch (to) {
                    // If the transition is to `.normal`, then ignore if for the same view:
                    .normal => if (header.view == self.view) return,
                    // If the transition is to `.view_change`, then ignore if the view has started:
                    .view_change => if (header.view == self.view) return,
                    else => unreachable,
                },
                .view_change => switch (to) {
                    // This is an interesting special case:
                    // If the transition is to `.normal` in the same view, then we missed the
                    // `start_view` message and we must also consider this a view jump:
                    // If we don't handle this below then our `view_change_status_timeout` will fire
                    // and we will disrupt the cluster with another view change for a newer view.
                    .normal => {},
                    // If the transition is to `.view_change`, then ignore if for the same view:
                    .view_change => if (header.view == self.view) return,
                    else => unreachable,
                },
                else => unreachable,
            }

            switch (to) {
                .normal => {
                    if (header.view == self.view) {
                        assert(self.status == .view_change);

                        log.debug("{}: view_jump: waiting to exit view change", .{self.replica});
                    } else {
                        assert(header.view > self.view);
                        assert(self.status == .view_change or self.status == .normal);

                        log.debug("{}: view_jump: waiting to jump to newer view", .{self.replica});
                    }

                    // TODO Debounce and decouple this from `on_message()` by moving into `tick()`:
                    log.debug("{}: view_jump: requesting start_view message", .{self.replica});
                    self.send_header_to_replica(self.primary_index(header.view), .{
                        .command = .request_start_view,
                        .cluster = self.cluster,
                        .replica = self.replica,
                        .view = header.view,
                    });
                },
                .view_change => {
                    assert(header.view > self.view);
                    assert(self.status == .view_change or self.status == .normal);

                    if (header.view == self.view + 1) {
                        log.debug("{}: view_jump: jumping to view change", .{self.replica});
                    } else {
                        log.debug("{}: view_jump: jumping to next view change", .{self.replica});
                    }
                    self.transition_to_view_change_status(header.view);
                },
                else => unreachable,
            }
        }

        fn write_prepare(self: *Self, message: *Message, trigger: Journal.Write.Trigger) void {
            assert(message.references > 0);
            assert(message.header.command == .prepare);
            assert(message.header.view <= self.view);
            assert(message.header.op <= self.op);

            if (message.header.op == self.op_checkpoint) {
                assert(message.header.op == 0);
            } else {
                assert(message.header.op > self.op_checkpoint);
            }

            if (!self.journal.has(message.header)) {
                log.debug("{}: write_prepare: ignoring op={} checksum={} (header changed)", .{
                    self.replica,
                    message.header.op,
                    message.header.checksum,
                });
                return;
            }

            if (self.journal.writing(message.header.op, message.header.checksum)) {
                log.debug("{}: write_prepare: ignoring op={} checksum={} (already writing)", .{
                    self.replica,
                    message.header.op,
                    message.header.checksum,
                });
                return;
            }

            self.journal.write_prepare(write_prepare_callback, message, trigger);
        }

        fn write_prepare_callback(
            self: *Self,
            wrote: ?*Message,
            trigger: Journal.Write.Trigger,
        ) void {
            // `null` indicates that we did not complete the write for some reason.
            const message = wrote orelse return;

            self.send_prepare_ok(message.header);
            defer self.flush_loopback_queue();

            switch (trigger) {
                .append => {},
                // If this was a repair, continue immediately to repair the next prepare:
                // This is an optimization to eliminate waiting until the next repair timeout.
                .repair => self.repair(),
                .pipeline => self.repair(),
                .fix => unreachable,
            }
        }
    };
}
