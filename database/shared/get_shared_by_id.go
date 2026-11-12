package shared

import (
	"database/sql"
	"fmt"

	"github.com/MertJSX/folderhost/database"
	"github.com/MertJSX/folderhost/types"
)

func GetSharedByID(id string) (*types.Shared, error) {
	row := database.DB.QueryRow("SELECT id, username, userID, displayName, path, password, expires_at, downloadCount, file_extension, is_static, created_at FROM shared WHERE id=?", id)

	var record types.Shared
	var password sql.NullString
	var expiresAt sql.NullString
	var fileExtension sql.NullString
	var createdAt sql.NullString

	err := row.Scan(
		&record.ID,
		&record.Username,
		&record.UserID,
		&record.DisplayName,
		&record.Path,
		&password,
		&expiresAt,
		&record.DownloadCount,
		&fileExtension,
		&record.IsStatic,
		&createdAt,
	)

	if err != nil {
		if err == sql.ErrNoRows {
			return nil, fmt.Errorf("shared not found")
		}
		return nil, fmt.Errorf("error getting shared from db: %w", err)
	}

	if password.Valid {
		record.Password = password.String
	}
	if expiresAt.Valid {
		record.ExpiresAt = expiresAt.String
	}
	if createdAt.Valid {
		record.CreatedAt = createdAt.String
	}
	if fileExtension.Valid {
		record.FileExtension = fileExtension.String
	}

	return &record, nil
}
