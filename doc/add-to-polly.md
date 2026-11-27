# "Add to Polly" links

A web application can offer an **Add to Polly** button that opens Polly's add-source form, filled in. The user
sees what will be added, enters the password or token, tests the connection and adds it. A link never adds a
source by itself.

```html
<a href="polly-monitor://add?type=feed&amp;url=https%3A%2F%2Fsla.example.com%2Fpolly.json%3Flist%3Dmine&amp;name=SLA%20tickets&amp;header=X-API-Key">Add to Polly</a>
<small>Requires Polly on your Mac, iPhone or iPad.</small>
```

The link works in Polly for Mac, iPhone and iPad.

## Parameters

Percent-encode every value (`encodeURIComponent` in JavaScript).

| Parameter  | Required | Meaning |
|------------|----------|---------|
| `url`      | yes      | The source's address: `http` or `https` only. |
| `type`     | no       | `nagios` (default), `url` or `feed`. |
| `name`     | no       | The name shown in Polly; defaults to the host name. |
| `username` | no       | For HTTP Basic authentication; the user enters the password. |
| `header`   | no       | Sign in with this header instead, such as `X-API-Key` or `Authorization`; the user enters its value. |

Other parameters are ignored, so a link made for a newer Polly still works.

## What Polly refuses

- **Secrets.** A link with a `password`, `token`, `value`, `key`, `secret` or `apikey` parameter, or with
  `user:password@` in the URL, is refused with an explanation. Links end up in browser history, server logs and
  screenshots. Show the token next to the button for the user to paste, or give each user a feed URL that is
  itself unguessable.
- **Anything but a web address.** `file:`, `javascript:` and other schemes are refused, so a web page can't
  point Polly at files on the user's computer.
- Unknown types, invalid header names and links longer than 2048 characters.

When the user already has a source with the same type, URL and username, Polly shows that source instead of
adding it again.

## When Polly isn't installed

A web page can't reliably tell whether Polly is installed; clicking the link then does nothing or shows a
browser error. Put a short "Requires Polly" note next to the button. See
[issue #90](https://github.com/WebHare/polly/issues/90) for better options.
