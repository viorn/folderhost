# Permanent (static) file links

FolderHost's regular share links are token based: `/share/:id` opens a page, and
the actual download goes through a one-time `/download?id=...` token that lives
for about a minute. That is fine for interactive downloads, but not for links
that must stay valid forever (avatars, embeds, direct downloads, scripts, etc.).

This fork adds a second, independent share type: **permanent (static) links**.

## URL format

```
https://your-host/s/<share-id>
```

The URL never changes and contains no token, no password and no expiration.

Optional query parameters:

| Parameter | Meaning |
|-----------|---------|
| `inline=1` | Render the file in the browser instead of downloading it. Only applied to safe types (images, video, audio, PDF, plain text, Markdown, CSV). HTML, SVG, JS and other active content is always sent as an attachment. |

Examples:

```
https://files.example.com/s/2d4af4100a3bedc702d4727072babf4f
https://files.example.com/s/2d4af4100a3bedc702d4727072babf4f?inline=1
```

## Creating a permanent link

There are two ways:

1. **One click:** select the file in the explorer and press **Permanent link**
   in the file info panel. The `/s/<id>` URL is created (or reused) and copied
   to the clipboard immediately.
2. **Share dialog:** open **Share**, find the **Permanent Link** section at the
   top and click **Create Permanent Link**, then copy the URL.

A file can have both a regular share link and a permanent link at the same time;
they are stored as separate records and have different IDs.

Deleting the permanent link in the dialog (or deleting the shared record) removes
the URL immediately. If the underlying file is deleted, the URL returns `404`.

## Behaviour and security

- Only users with the **download** permission can create static links.
- Only existing files can be shared; directories are rejected.
- Passwords and expiration dates are intentionally ignored/cleared for static
  shares, because the point of the link is to be permanent and public.
- Every request re-checks that the owner still exists, still has the download
  permission, and that the file is still inside the owner's scope.
- Download counters are incremented on each non-cached request.
- Responses are sent with `X-Content-Type-Options: nosniff` and
  `Cache-Control: public, max-age=300`.

## API

Create (the regular endpoint, with `isStatic: true`):

```http
POST /api/shared
Authorization: <token>
Content-Type: application/json

{
  "shared": {
    "path": "/folder/file.png",
    "displayName": "file.png",
    "isStatic": true
  }
}
```

Fetch the static record for a path:

```http
GET /api/shared/folder/file.png?static=true
Authorization: <token>
```

Delete the static record for a path:

```http
DELETE /api/shared/folder/file.png?static=true
Authorization: <token>
```

Serve the file publicly:

```http
GET /s/:id
GET /s/:id/:filename   # filename is cosmetic, ignored
```

## Database migration

A new `is_static` column is added to the `shared` table automatically on start-up.
Existing shares keep `is_static = 0` and continue to work as before.
