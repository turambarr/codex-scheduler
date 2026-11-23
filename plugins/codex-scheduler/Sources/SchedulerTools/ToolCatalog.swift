import MCP

/// Phase-1 tool surface.
///
/// Every tool is read-only with respect to Apple Calendar and Reminders: the tools
/// list sources, read entries, compute free time and build an inert schedule plan.
/// `preview_schedule` describes what *would* be created and performs no writes.
public enum ToolCatalog {
    public static let minimumTool = "find_free_slots"
    public static let planTool = "plan_tasks"
    public static let previewTool = "preview_schedule"

    /// Every phase-1 tool is declared read-only at the protocol level, so a client can
    /// enforce the guarantee without inspecting the implementation.
    public static var tools: [Tool] {
        baseTools.map { tool in
            var tool = tool
            tool.annotations = Tool.Annotations(readOnlyHint: true, openWorldHint: false)
            return tool
        }
    }

    public static var managedTools: [Tool] {
        let id = stringField("变更预览的 plan_id。")
        let zone = stringField("排程时区，默认本机时区。")
        let definitions: [(String, String, [String: Value], [String])] = [
            ("propose_reminder", "预览新增自管提醒，保持原清单完整。", [
                "title": stringField("提醒标题。"), "remind_at": stringField("包含日期和时刻的时间。"),
                "task_id": stringField("可选的已有自管任务标识。"), "time_zone": zone,
            ], ["title", "remind_at"]),
            ("list_managed_items", "列出由本服务创建且有写入记录的事项。", ["time_zone": zone], []),
            ("reschedule", "预览自管事项改期。给出 start 时保留原时长，省略时按实际占用为日历时间块寻找空档。", [
                "item_id": stringField("自管事项标识。"), "start": stringField("可选的新开始时刻。"),
                "range_start": stringField("自动查找范围起点。"), "range_end": stringField("自动查找范围终点。"),
                "deadline": stringField("自动查找的任务截止时间。"),
                "busy_blocks": arrayField(busySchema, "额外固定占用。"),
                "working_windows": arrayField(workingWindowSchema, "覆盖本次工作窗口。"), "time_zone": zone,
            ], ["item_id"]),
            ("complete_task", "预览完成自管任务，标记关联提醒完成并释放其未来自管时间块。", [
                "task_id": stringField("自管任务标识。"), "time_zone": zone,
            ], ["task_id"]),
            ("undo_schedule", "为已提交变更生成反向预览。", ["plan_id": id, "time_zone": zone], ["plan_id"]),
            ("commit_schedule", "展示预览后，在 Codex 对话中请求用户确认。用户确认后写入并返回结果。", ["plan_id": id], ["plan_id"]),
            ("schedule_status", "核对提交进度与已写入的变更数。", ["plan_id": id], ["plan_id"]),
        ]
        return definitions.map { name, description, properties, required in
            Tool(name: name, description: description, inputSchema: schema(properties: properties, required: required),
                 annotations: .init(readOnlyHint: name == "schedule_status" || name == "list_managed_items", openWorldHint: false))
        }
    }

    private static var baseTools: [Tool] {
        [
            Tool(
                name: "list_calendars",
                title: "列出日历与提醒事项清单",
                description: """
                列出本机可访问的事件日历与提醒事项清单，返回稳定标识、来源、类型和是否可编辑。
                只读；不会修改任何数据。后续工具用这里的标识做过滤。
                """,
                inputSchema: schema(
                    properties: [
                        "kind": enumField(["event", "reminder", "all"], "要列出的类型，默认 all。"),
                    ],
                    required: []
                )
            ),
            Tool(
                name: "list_events",
                title: "读取日历事件",
                description: """
                读取指定时间范围内的事件实例，返回起止时间、忙闲状态、是否全天、是否重复以及所属日历。
                只读。已取消的事件会被跳过；availability 为 free 的事件视为不占用时间。
                """,
                inputSchema: schema(
                    properties: [
                        "start": stringField("范围起点，YYYY-MM-DD 或带时区的 ISO-8601 时间。"),
                        "end": stringField("范围终点，YYYY-MM-DD 表示到该日结束。"),
                        "calendar_ids": arrayField(stringField("日历标识"), "只读取这些日历；省略表示全部。"),
                        "include_notes": booleanField("是否包含备注，默认 false。"),
                        "time_zone": stringField("IANA 时区标识，默认本机时区。"),
                    ],
                    required: []
                )
            ),
            Tool(
                name: "list_reminders",
                title: "读取提醒事项",
                description: """
                读取提醒事项，默认包含未完成项、逾期项和未设日期的项。
                只读。priority 为 EventKit 的 1–9（0 表示未设置），scheduler_priority 为映射后的 1–5。
                """,
                inputSchema: schema(
                    properties: [
                        "list_ids": arrayField(stringField("提醒事项清单标识"), "只读取这些清单；省略表示全部。"),
                        "include_completed": booleanField("是否包含已完成项，默认 false。"),
                        "due_from": stringField("到期时间下界（可选）。"),
                        "due_to": stringField("到期时间上界（可选）。"),
                        "limit": integerField("最多返回多少条，默认 100，最大 500。"),
                        "offset": integerField("分页起点，默认 0。使用上一次返回的 next_offset 继续。"),
                        "include_notes": booleanField("是否包含备注，默认 false。"),
                        "time_zone": stringField("IANA 时区标识，默认本机时区。"),
                    ],
                    required: []
                )
            ),
            Tool(
                name: "find_free_slots",
                title: "计算空闲时段",
                description: """
                在指定范围内按工作窗口减去忙碌事件，返回可用的连续空闲时段，并列出被排除的忙碌项和原因。
                只读。用于回答“这周还有哪些空档”这类问题。
                """,
                inputSchema: schema(
                    properties: [
                        "start": stringField("范围起点，YYYY-MM-DD 或带时区的 ISO-8601 时间。"),
                        "end": stringField("范围终点，YYYY-MM-DD 表示到该日结束。"),
                        "minimum_minutes": integerField("只返回不短于该分钟数的空档，默认 30。"),
                        "calendar_ids": arrayField(stringField("日历标识"), "只把这些日历算作忙碌；省略表示全部。"),
                        "use_calendar": booleanField("是否查询真实日历，默认 true。"),
                        "busy_blocks": arrayField(busySchema, "额外固定占用，例如用户确认要参加的课程。"),
                        "working_windows": arrayField(workingWindowSchema, "本次查询使用的完整每周工作窗口；省略则沿用默认。"),
                        "include_excluded": booleanField("是否返回被排除的忙碌项明细，默认 true。"),
                        "time_zone": stringField("IANA 时区标识，默认本机时区。"),
                    ],
                    required: []
                )
            ),
            Tool(
                name: "plan_tasks",
                title: "生成排程计划",
                description: """
                把任务、偏好和当前日历占用一起喂给确定性排程引擎，产出不可执行的计划：
                每个任务被放到哪个时间块、哪些任务排不下及原因、工时缺口、采用的假设与告警。
                计划会保存在本机 SQLite 中，返回 plan_id 供 preview_schedule 使用。
                只读：本工具不会写入日历或提醒事项。
                """,
                inputSchema: schema(
                    properties: [
                        "range_start": stringField("规划范围起点。"),
                        "range_end": stringField("规划范围终点；YYYY-MM-DD 表示到该日结束。"),
                        "tasks": arrayField(taskSchema, "要排的任务，至少一个。"),
                        "use_calendar": booleanField("是否读取本机日历作为忙碌时间，默认 true。"),
                        "calendar_ids": arrayField(stringField("日历标识"), "只把这些日历算作忙碌。"),
                        "busy_blocks": arrayField(busySchema, "额外指定的忙碌时段（可选）。"),
                        "working_windows": arrayField(workingWindowSchema, "本次排程使用的完整每周工作窗口；省略则沿用默认。"),
                        "granularity_minutes": integerField("时间块对齐粒度，默认 15。"),
                        "buffer_workdays": integerField("距离截止的工作日安全余量，默认 1。"),
                        "target_position": numberField("时间块在可行窗口中的理想位置，0–1，默认 0.45。"),
                        "max_session_minutes": integerField("单个时间块上限，默认 90。"),
                        "min_chunk_minutes": integerField("拆分后的最小时块，默认 30。"),
                        "time_zone": stringField("IANA 时区标识，默认本机时区。"),
                    ],
                    required: ["tasks"]
                )
            ),
            Tool(
                name: "preview_schedule",
                title: "生成变更预览",
                description: """
                读取已保存的计划并生成人类可读的变更预览：拟创建的时间块、与当前日历的冲突、授权范围与有效期。
                第一阶段只展示，不执行任何写入；返回的 operations 需要在后续阶段由用户确认后才会提交。
                冲突检查依赖日历读取权限；没有权限或 use_calendar=false 时会明确返回 conflict_check，表示冲突未被验证。
                """,
                inputSchema: schema(
                    properties: [
                        "plan_id": stringField("plan_tasks 返回的计划标识。"),
                        "use_calendar": booleanField("是否重读日历做冲突检查，默认 true；设为 false 时返回 conflict_check: skipped_by_request。"),
                        "time_zone": stringField("展示用 IANA 时区标识，默认沿用计划的时区。"),
                    ],
                    required: ["plan_id"]
                )
            ),
        ]
    }

    // MARK: - Schema helpers

    private static func schema(properties: [String: MCP.Value], required: [String]) -> MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    private static func stringField(_ description: String) -> MCP.Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerField(_ description: String) -> MCP.Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func numberField(_ description: String) -> MCP.Value {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static func booleanField(_ description: String) -> MCP.Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func arrayField(_ items: MCP.Value, _ description: String) -> MCP.Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": items,
        ])
    }

    private static func enumField(_ values: [String], _ description: String) -> MCP.Value {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map { .string($0) }),
        ])
    }

    private static var taskSchema: MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "id": stringField("任务稳定标识；省略时自动生成。"),
                "title": stringField("任务标题。"),
                "estimated_minutes": integerField("预估总时长（分钟）。"),
                "remaining_minutes": integerField("剩余时长（分钟），省略等于预估时长。"),
                "priority": integerField("优先级 1（最高）–5（最低），默认 3。"),
                "earliest_start": stringField("最早开始时间（可选）。"),
                "deadline": stringField("截止时间；纯日期表示到那天结束，带时区表示精确时刻。"),
                "splittable": booleanField("是否允许拆成多个时间块，默认 true。"),
                "min_chunk_minutes": integerField("拆分时单个时间块的最小分钟数，默认 30。"),
                "preference": enumField(["morning", "afternoon", "any"], "时段偏好，默认 any。"),
                "depends_on": arrayField(stringField("前置任务标识"), "必须先完成的任务标识。"),
                "allow_concurrent_with": arrayField(stringField("任务标识"), "允许与之共享时段的任务；必须双向声明。"),
                "notes": stringField("备注。"),
                "source": enumField(["reminder", "user_request", "plan", "external"], "任务来源，默认 user_request。"),
            ]),
            "required": .array([.string("title"), .string("estimated_minutes")]),
            "additionalProperties": .bool(false),
        ])
    }

    private static var busySchema: MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "title": stringField("忙碌项标题。"),
                "start": stringField("开始时间。"),
                "end": stringField("结束时间。"),
                "availability": enumField(["busy", "free", "tentative", "unavailable", "unknown"], "默认 busy。"),
            ]),
            "required": .array([.string("title"), .string("start"), .string("end")]),
            "additionalProperties": .bool(false),
        ])
    }

    private static var workingWindowSchema: MCP.Value {
        schema(properties: [
            "weekday": integerField("1 为周日，2 为周一，依此类推。"),
            "start": stringField("当地开始时间，HH:mm。"),
            "end": stringField("当地结束时间，HH:mm。"),
        ], required: ["weekday", "start", "end"])
    }
}
