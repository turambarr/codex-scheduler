# Privacy

Codex Scheduler is a macOS application and local MCP server. It requests access to Apple Calendar and Reminders to read the items needed for a request and check scheduling conflicts. It writes only to its bound calendar and reminder list, after approval in the client.

The application maintains a local SQLite database at `~/Library/Application Support/CodexScheduler/plans.sqlite` by default. It stores plans, task and item identifiers, calendar and list bindings, and the outcome of write requests.

The scheduler does not send data to a developer-operated service. It returns tool results to the calling Codex or MCP client, which can process and retain them under its own settings and terms. Apple account synchronization follows the settings for the calendar or reminder list on the device.

You can revoke the application's access in macOS System Settings under Privacy & Security. To remove locally stored plans, quit the scheduler clients and remove its database. To remove saved calendar and reminder items, use Apple's Calendar or Reminders app.

For questions, open an issue at [Codex Scheduler](https://github.com/turambarr/codex-scheduler/issues). Use an example with fictitious event titles and times.
