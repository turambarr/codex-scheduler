#!/usr/bin/env python3
"""End-to-end smoke test for the codex-scheduler MCP server.

Speaks JSON-RPC over the application launcher's standard input and output,
then checks planning and preview:

    initialize -> tools/list -> plan_tasks -> preview_schedule

`use_calendar` is set to false and the busy time is passed inline, so the test
works on a machine where the calendar permission has not been granted yet.

Usage:
    python3 scripts/smoke-mcp.py                 # uses the configured app launcher
    python3 scripts/smoke-mcp.py --bin path/to/CodexScheduler
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BIN = os.path.join(ROOT, "scripts", "launch-mcp.sh")


class Client:
    def __init__(self, binary: str, env: dict[str, str]) -> None:
        self.proc = subprocess.Popen(
            [binary, "mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
            bufsize=1,
        )
        self.next_id = 1

    def send(self, method: str, params: dict) -> int:
        request_id = self.next_id
        self.next_id += 1
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        return request_id

    def notify(self, method: str, params: dict | None = None) -> None:
        payload = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def read_result(self) -> dict:
        while True:
            line = self.proc.stdout.readline()
            if not line:
                stderr = self.proc.stderr.read()
                raise RuntimeError(f"server closed stdout unexpectedly\n--- stderr ---\n{stderr}")
            message = json.loads(line)
            if "id" in message:
                if "error" in message:
                    raise RuntimeError(f"JSON-RPC error: {message['error']}")
                return message["result"]

    def close(self) -> None:
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def tool_payload(result: dict) -> dict:
    """Tool results carry a JSON document inside the first text content block."""
    if result.get("isError"):
        raise RuntimeError(f"tool reported an error: {result['content'][0]['text']}")
    return json.loads(result["content"][0]["text"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default=DEFAULT_BIN)
    parser.add_argument("--time-zone", default="Asia/Shanghai")
    parser.add_argument("--live", action="store_true", help="核验真实读取，仅打印计数与诊断")
    args = parser.parse_args()

    if not os.access(args.bin, os.X_OK):
        print(f"找不到可执行文件：{args.bin}", file=sys.stderr)
        return 2

    store = os.path.join(tempfile.mkdtemp(prefix="codex-scheduler-smoke-"), "plans.sqlite")
    env = dict(os.environ, CODEX_SCHEDULER_STORE=store)

    client = Client(args.bin, env)
    failures: list[str] = []

    def check(condition: bool, label: str) -> None:
        status = "ok  " if condition else "FAIL"
        print(f"  [{status}] {label}")
        if not condition:
            failures.append(label)

    try:
        client.send(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {
                    "experimental": {"codex/auth-change": {}},
                    "elicitation": {"form": {}, "url": {}},
                },
                "clientInfo": {"name": "smoke", "version": "0.1.0"},
            },
        )
        info = client.read_result()
        check(info.get("protocolVersion") is not None, "initialize 返回协议版本")
        check(info.get("capabilities", {}).get("tools", {}).get("listChanged") is False, "声明 tools 能力")
        client.notify("notifications/initialized")

        client.send("tools/list", {})
        tools = client.read_result()["tools"]
        names = sorted(tool["name"] for tool in tools)
        check(
            names
            == sorted(
                [
                    "list_calendars",
                    "list_events",
                    "list_reminders",
                    "find_free_slots",
                    "plan_tasks",
                    "preview_schedule",
                    "propose_reminder",
                    "list_managed_items",
                    "reschedule",
                    "complete_task",
                    "undo_schedule",
                    "commit_schedule",
                    "schedule_status",
                ]
            ),
            f"tools/list 返回 13 个工具（实际 {len(names)}）",
        )
        flags = {tool["name"]: tool.get("annotations", {}).get("readOnlyHint") for tool in tools}
        check(flags["list_events"] is True and flags["commit_schedule"] is False, "读取和提交工具区分修改权限")

        if args.live:
            def read(name: str, **arguments) -> dict | None:
                client.send("tools/call", {"name": name, "arguments": arguments})
                try:
                    return tool_payload(client.read_result())
                except RuntimeError as error:
                    check(False, f"{name} {error}")
                    return None

            events = read("list_events", time_zone=args.time_zone)
            if events is not None:
                check("range" in events, f"已读取未来七天日历，共 {events['count']} 项")
            seen = 0
            offset = 0
            while True:
                reminders = read("list_reminders", time_zone=args.time_zone, offset=offset)
                if reminders is None:
                    break
                seen += reminders["count"]
                following = reminders.get("next_offset")
                if following is None:
                    check(seen == reminders["total"], f"已读取未完成提醒，共 {seen} 项")
                    break
                if following <= offset:
                    check(False, "提醒事项的分页没有前进")
                    break
                offset = following
            if events is not None:
                free = read("find_free_slots", time_zone=args.time_zone)
                check(free is not None and free["calendar_checked"], "按真实日历计算空闲时段")
                plan = read("plan_tasks", time_zone=args.time_zone, tasks=[
                    {"title": "排程核验", "estimated_minutes": 120, "splittable": False}
                ])
                if plan is not None:
                    preview = read("preview_schedule", plan_id=plan["plan_id"])
                    check(preview is not None
                          and preview["conflict_check"] == "checked_against_calendar"
                          and preview["authorization"]["write_performed"] is False,
                          "生成排程预览并重新核对真实日历")
                    if preview is not None and preview["operations"] and not preview["conflicts"]:
                        check(preview["authorization"]["commit_available"] is True
                              and preview["authorization"]["requires_human_confirmation"] is True,
                              "可提交的排程需要用户确认")
            return int(bool(failures))

        # The server uses wall-clock "now", so the planning range must lie in the future.
        # Two weeks guarantees at least a couple of workdays under the default config.
        first_day = datetime.date.today() + datetime.timedelta(days=1)
        last_day = first_day + datetime.timedelta(days=13)
        busy_day = first_day.isoformat()
        client.send(
            "tools/call",
            {
                "name": "plan_tasks",
                "arguments": {
                    "time_zone": args.time_zone,
                    "range_start": first_day.isoformat(),
                    "range_end": last_day.isoformat(),
                    "use_calendar": False,
                    "busy_blocks": [
                        {"title": "组会", "start": f"{busy_day}T09:00", "end": f"{busy_day}T10:00"}
                    ],
                    "tasks": [
                        {"id": "t1", "title": "写开题报告", "estimated_minutes": 60, "priority": 2},
                        {"id": "t2", "title": "回邮件", "estimated_minutes": 30, "priority": 4},
                    ],
                },
            },
        )
        plan = tool_payload(client.read_result())
        plan_id = plan.get("plan_id")
        assignments = plan.get("assignments", [])
        check(bool(plan_id), f"plan_tasks 生成 plan_id（{plan_id}）")
        check(plan.get("saved") is True, "计划已落盘")
        check(len(assignments) >= 1, f"排出了时间块（{len(assignments)} 个）")
        planned_minutes = sum(a["minutes"] for a in assignments)
        check(planned_minutes == 90, f"两个任务共 90 分钟（实际 {planned_minutes}）")

        def minutes_of(text: str) -> int:
            hour, minute = text.split(":")
            return int(hour) * 60 + int(minute)

        overlaps_busy = [
            a
            for a in assignments
            if a["date"] == busy_day
            and minutes_of(a["start_time"]) < 10 * 60
            and 9 * 60 < minutes_of(a["end_time"])
        ]
        check(not overlaps_busy, f"没有和 {busy_day} 09:00–10:00 的组会重叠")
        weekend = [a for a in assignments if datetime.date.fromisoformat(a["date"]).weekday() >= 5]
        check(not weekend, "所有时间块都落在工作日（周一至周五）")
        client.send(
            "tools/call",
            {"name": "preview_schedule", "arguments": {"plan_id": plan_id, "use_calendar": False}},
        )
        preview = tool_payload(client.read_result())
        check(preview.get("plan_id") == plan_id, "preview 读回同一份计划")
        check(preview.get("conflict_check") == "skipped_by_request", "预览明确标注冲突检查已跳过")
        check(preview.get("conflicts") == [], "跳过检查时不虚构冲突")
        check(len(preview.get("operations", [])) == len(assignments), "预览为每个时间块生成一条操作")
        authorization = preview.get("authorization", {})
        check(authorization.get("write_performed") is False, "预览未修改苹果日历和提醒事项")
        check(authorization.get("commit_available") is False, "未检查日历冲突的预览不可提交")
        print(f"  预览：{preview.get('summary', {}).get('headline')}")

        client.send("tools/call", {
            "name": "propose_reminder",
            "arguments": {"title": "测试提醒", "remind_at": f"{last_day.isoformat()}T10:00:00+08:00"},
        })
        reminder_preview = tool_payload(client.read_result())
        check(reminder_preview.get("status") == "preview", "新增提醒先生成预览")
        check(reminder_preview.get("write_performed") is False, "提醒预览不写入苹果清单")

        client.send("tools/call", {"name": "no_such_tool", "arguments": {}})
        error_result = client.read_result()
        check(error_result.get("isError") is True, "未知工具返回 isError")
        body = json.loads(error_result["content"][0]["text"])
        check(body.get("write_performed") is False, "错误体声明未发生写入")
    finally:
        client.close()

    if failures:
        print(f"\n失败 {len(failures)} 项：")
        for item in failures:
            print(f"  - {item}")
        return 1

    print(f"\n全部通过。计划存储：{store}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
