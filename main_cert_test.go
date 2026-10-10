package main

import (
	"errors"
	"testing"

	"github.com/mhsanaei/3x-ui/v3/database/model"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestCertificateSettingsAtomic(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()
	if err := db.AutoMigrate(&model.Setting{}); err != nil {
		t.Fatal(err)
	}
	if err := saveCertificateSettings(db, "old-cert", "old-key"); err != nil {
		t.Fatal(err)
	}
	writes := 0
	db.Callback().Update().Before("gorm:update").Register("test:failure", func(tx *gorm.DB) {
		writes++
		if writes == 2 {
			tx.AddError(errors.New("disk write failure"))
		}
	})
	if err := saveCertificateSettings(db, "new-cert", "new-key"); err == nil {
		t.Fatal("expected write failure")
	}
	db.Callback().Update().Remove("test:failure")
	var settings []model.Setting
	if err := db.Find(&settings).Error; err != nil {
		t.Fatal(err)
	}
	if len(settings) != 4 {
		t.Fatalf("got %d settings", len(settings))
	}
	for _, s := range settings {
		if s.Value != "old-cert" && s.Value != "old-key" {
			t.Fatalf("partial update: %s", s.Key)
		}
	}
	if err := saveCertificateSettings(db, "", ""); err != nil {
		t.Fatal(err)
	}
	db.Find(&settings)
	for _, s := range settings {
		if s.Value != "" {
			t.Fatalf("reset failed: %s", s.Key)
		}
	}
}

func TestCertificateInvalidPair(t *testing.T) {
	if err := updateCert("missing-cert", ""); err == nil {
		t.Fatal("accepted one missing path")
	}
	if err := updateCert("missing-cert", "missing-key"); err == nil {
		t.Fatal("accepted nonexistent files")
	}
}
