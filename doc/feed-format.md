# Polly feed format

A Polly feed is a JSON document that lists the things that need attention, such as SLA tickets, open merge
requests or anything else a server can count. Polly shows each listed item as a problem, next to the problems of
its Nagios servers and URLs. Add a feed in Polly with the type **Feed** and the URL of the document.

The server decides what is wrong and how bad it is. Polly doesn't interpret the items: it shows them, counts them
and notifies when they change.

## Example

```json
{
  "polly": 1,
  "url": "https://portal.example.com/tickets",
  "okCount": 14,
  "noun": { "one": "ticket", "other": "tickets" },
  "items": [
    {
      "id": "ticket-48213",
      "group": "utwente_base",
      "title": "Copy pasting inline widgets broken since the last release",
      "severity": "warning",
      "since": "2026-11-26T20:54:15+01:00",
      "due": "2026-12-03T13:00:00+01:00",
      "summary": "Unconfirmed · P4 · deadline 03-12 13:00",
      "details": "Labels: P4, GitLab issue",
      "acknowledged": false,
      "url": "https://portal.example.com/ticket/48213",
      "fields": [
        { "label": "Status", "value": "Unconfirmed" },
        { "label": "Assigned to", "value": "Rob" }
      ]
    }
  ]
}
```

## Document

| Key       | Required | Meaning |
|-----------|----------|---------|
| `polly`   | yes      | Format version, `1`. Polly refuses a version it doesn't know, and asks the user to update Polly. |
| `items`   | yes      | The items that need attention. **Only** list problems; everything listed is shown as one. An empty list means all is well. |
| `okCount` | no       | How many items are fine. Only counted: "16 tickets OK", or "16 tickets, 1 crit, 1 warn". Default 0. |
| `noun`    | no       | What the items are called, `{ "one": "ticket", "other": "tickets" }`. Default item/items. |
| `url`     | no       | A web page for the whole feed; opened for items without their own `url`. |
| `error`   | no       | A message instead of items, shown as the reason the source can't be read. |

Other keys are ignored, so a feed can carry more than Polly uses.

## Items

| Key            | Required | Meaning |
|----------------|----------|---------|
| `id`           | yes      | Stable, unique key (a text or a whole number). Notifications compare items by id, so keep it the same while the item exists, also when its title changes. |
| `group`        | yes      | Shown where Nagios shows the host: the customer, project or system. May be empty. |
| `title`        | yes      | Shown where Nagios shows the service. |
| `severity`     | yes      | `critical`, `warning` or `unknown`. Decides the grouping, Polly's mood and the notifications. Raise it as a deadline comes closer to get a notification. |
| `since`        | no       | When the item got its current severity (not when it was created): the age in the list. |
| `due`          | no       | Deadline, shown in the detail as "in 6d" or "2h overdue". |
| `summary`      | no       | One line, shown under the title and as the first output line of the detail. |
| `details`      | no       | More text for the detail; may contain newlines. |
| `acknowledged` | no       | `true` when someone is on it: shown as ACK, and it doesn't notify. |
| `url`          | no       | The item's own page, opened by **Open in browser**. Only http and https links are used. |
| `fields`       | no       | Extra `{ "label": …, "value": … }` facts for the detail, shown in this order. |

Dates are ISO 8601 with a time zone, such as `2026-11-27T10:15:00+01:00` or `2026-11-27T09:15:00Z`; fractions
of seconds are allowed.

## Requests and errors

- Polly sends a `GET` with `Accept: application/json` to the URL exactly as entered, query included, every
  60 seconds. It doesn't follow redirects, so the credentials stay with this server.
- Authentication is either HTTP Basic (username and password), or a custom header with a secret value, such as
  `X-API-Key: <key>` or `Authorization: Bearer <token>`. The server knows who asks, so a personal list
  ("my tickets") works by the credentials; use a separate URL for each list, such as `?list=mine`, so each gets
  its own switch and notification bell in Polly.
- Answer with HTTP 200 and the document. Any other status makes the source unreachable; a JSON body with
  `{"error": "Token expired"}` is shown as the reason. HTTP 401 and 403 are reported as failed authentication.
- A document that breaks these rules (a missing required key, an unknown severity, a duplicate id or an invalid
  date) is refused as a whole, with a message naming the item, so mistakes are visible rather than quietly
  dropped.
- Feeds are read-only: Polly can't acknowledge or snooze items.

## Feed files

On a Mac, Polly can also read a feed from a JSON file, for a script that writes the list instead of a server
that serves it. Choose the file with **Browse…** in the add-source form.

- Write the whole file at once (write a temporary file and rename it), so Polly never reads half a document.
- Rewrite it regularly, also when nothing changed. Polly uses the file's modification time to tell whether the
  writer is still running: a file that hasn't changed for longer than the source's limit (15 minutes unless
  set otherwise) is reported as stale.
