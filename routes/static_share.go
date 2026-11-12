package routes

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/MertJSX/folderhost/database"
	"github.com/MertJSX/folderhost/database/logs"
	"github.com/MertJSX/folderhost/database/shared"
	"github.com/MertJSX/folderhost/database/users"
	"github.com/MertJSX/folderhost/types"
	"github.com/MertJSX/folderhost/utils"
	"github.com/gofiber/fiber/v2"
)

// staticInlineExtensions lists file types that are safe to render in the
// browser. Everything else (html, svg, js, ...) is always served as an
// attachment to avoid stored XSS on the folderhost origin.
var staticInlineExtensions = map[string]bool{
	".png":  true,
	".jpg":  true,
	".jpeg": true,
	".gif":  true,
	".webp": true,
	".avif": true,
	".bmp":  true,
	".ico":  true,
	".mp4":  true,
	".webm": true,
	".mp3":  true,
	".ogg":  true,
	".wav":  true,
	".pdf":  true,
	".txt":  true,
	".md":   true,
	".csv":  true,
}

// StaticShare serves a file through a permanent, token-less URL: /s/:id
// Only records explicitly created as static are served here.
func StaticShare(c *fiber.Ctx) error {
	id := c.Params("id")
	if id == "" {
		return c.Status(400).SendString("Bad request")
	}

	record, err := shared.GetSharedByID(id)
	if err != nil || !record.IsStatic {
		return c.Status(404).SendString("Not found")
	}

	if record.ExpiresAt != "" {
		expiresTime, err := time.Parse(time.RFC3339, record.ExpiresAt)
		if err == nil && time.Now().After(expiresTime) {
			return c.Status(410).SendString("This link has expired")
		}
	}

	if record.Password != "" && record.Password != c.Query("password") {
		return c.Status(401).SendString("Password required")
	}

	user, err := users.GetUserByUsername(record.Username)
	if err != nil {
		return c.Status(404).SendString("The owner of this shared file no longer exists")
	}

	if !user.Permissions.DownloadFiles {
		return c.Status(403).SendString("Sharing is disabled for the owner of this file")
	}

	if ok := utils.IsSafePathForScope(record.Path, user.Scope); !ok {
		return c.Status(403).SendString("This file is no longer within the user's scope")
	}

	fileinfo, err := os.Stat(record.Path)
	if os.IsNotExist(err) || fileinfo.IsDir() {
		shared.DeleteShared(record.ID)
		return c.Status(404).SendString("File no longer exists")
	}

	_, err = database.DB.Exec("UPDATE shared SET downloadCount = downloadCount + 1 WHERE id=?", record.ID)
	if err != nil {
		fmt.Println("Error updating downloadCount:", err)
	}

	logs.CreateLog(types.AuditLog{
		Username:    record.Username,
		Action:      "Download",
		Description: fmt.Sprintf("Static link %s was used to download %s", record.ID, record.Path),
	})

	filename := strings.ReplaceAll(filepath.Base(record.Path), `"`, "")
	ext := strings.ToLower(filepath.Ext(filename))

	disposition := "attachment"
	if c.Query("inline") == "1" && staticInlineExtensions[ext] {
		disposition = "inline"
	}

	c.Set("Content-Disposition", fmt.Sprintf(`%s; filename="%s"`, disposition, filename))
	c.Set("X-Content-Type-Options", "nosniff")
	c.Set("Cache-Control", "public, max-age=300")

	return c.SendFile(record.Path)
}
