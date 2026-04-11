package model

import (
	"fmt"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/common"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func setupAffDailyCommissionTestDB(t *testing.T) *gorm.DB {
	t.Helper()

	dbName := fmt.Sprintf("file:aff_daily_commission_%d?mode=memory&cache=shared", time.Now().UnixNano())
	db, err := gorm.Open(sqlite.Open(dbName), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	sqlDB.SetMaxIdleConns(1)
	require.NoError(t, db.AutoMigrate(&User{}, &Log{}, &AffDailyCommissionSettlement{}))

	DB = db
	LOG_DB = db
	common.UsingSQLite = true
	common.UsingMySQL = false
	common.UsingPostgreSQL = false
	common.RedisEnabled = false
	common.LogConsumeEnabled = true
	initCol()
	return db
}

func createAffDailyCommissionUser(t *testing.T, user User) User {
	t.Helper()
	require.NoError(t, DB.Select("*").Create(&user).Error)
	require.NotZero(t, user.Id)
	if user.AffCommissionPercent == 0 {
		require.NoError(t, DB.Exec("UPDATE users SET aff_commission_percent = 0 WHERE username = ?", user.Username).Error)
	}
	return user
}

func createConsumeLogForDate(t *testing.T, userId int, quota int, targetDate time.Time) {
	t.Helper()
	log := Log{
		UserId:    userId,
		Username:  fmt.Sprintf("user-%d", userId),
		CreatedAt: time.Date(targetDate.Year(), targetDate.Month(), targetDate.Day(), 12, 0, 0, 0, time.Local).Unix(),
		Type:      LogTypeConsume,
		Quota:     quota,
		Content:   "test consume",
	}
	require.NoError(t, LOG_DB.Create(&log).Error)
}

func fetchUserForAffDailyCommissionTest(t *testing.T, userId int) User {
	t.Helper()
	var user User
	require.NoError(t, DB.First(&user, userId).Error)
	return user
}

func TestSettleAffDailyCommissionForDateGlobalPercent(t *testing.T) {
	setupAffDailyCommissionTestDB(t)
	common.AffCommissionPercentage = 1

	inviter := createAffDailyCommissionUser(t, User{
		Username:             "global-inviter",
		Password:             "password123",
		AffCode:              "aff-global-inviter",
		AffCommissionPercent: -1,
	})
	invitee := createAffDailyCommissionUser(t, User{
		Username:  "global-invitee",
		Password:  "password123",
		AffCode:   "aff-global-invitee",
		InviterId: inviter.Id,
	})
	targetDate := time.Date(2026, 4, 5, 0, 0, 0, 0, time.Local)
	createConsumeLogForDate(t, invitee.Id, 2300, targetDate)
	createConsumeLogForDate(t, invitee.Id, 700, targetDate)
	createConsumeLogForDate(t, invitee.Id, 9999, targetDate.AddDate(0, 0, -1))

	summary, err := SettleAffDailyCommissionForDate(targetDate)
	require.NoError(t, err)
	require.Equal(t, "2026-04-05", summary.SettleDate)
	require.Equal(t, 1, summary.InviteeCount)
	require.Equal(t, 1, summary.SettledCount)
	require.Equal(t, 1, summary.RewardedCount)
	require.EqualValues(t, 3000, summary.ConsumedQuota)
	require.EqualValues(t, 30, summary.CommissionQuota)

	inviter = fetchUserForAffDailyCommissionTest(t, inviter.Id)
	require.Equal(t, 30, inviter.Quota)
	require.Equal(t, 30, inviter.AffHistoryQuota)

	var settlement AffDailyCommissionSettlement
	require.NoError(t, DB.Where("invitee_id = ? AND settle_date = ?", invitee.Id, "2026-04-05").First(&settlement).Error)
	require.Equal(t, inviter.Id, settlement.InviterId)
	require.Equal(t, 3000, settlement.ConsumedQuota)
	require.Equal(t, 1, settlement.CommissionPercent)
	require.Equal(t, 30, settlement.CommissionQuota)
}

func TestSettleAffDailyCommissionForDateCustomPercent(t *testing.T) {
	setupAffDailyCommissionTestDB(t)
	common.AffCommissionPercentage = 1

	inviter := createAffDailyCommissionUser(t, User{
		Username:             "custom-inviter",
		Password:             "password123",
		AffCode:              "aff-custom-inviter",
		AffCommissionPercent: 25,
	})
	invitee := createAffDailyCommissionUser(t, User{
		Username:  "custom-invitee",
		Password:  "password123",
		AffCode:   "aff-custom-invitee",
		InviterId: inviter.Id,
	})
	targetDate := time.Date(2026, 4, 5, 0, 0, 0, 0, time.Local)
	createConsumeLogForDate(t, invitee.Id, 4000, targetDate)

	summary, err := SettleAffDailyCommissionForDate(targetDate)
	require.NoError(t, err)
	require.Equal(t, 1, summary.RewardedCount)
	require.EqualValues(t, 1000, summary.CommissionQuota)

	inviter = fetchUserForAffDailyCommissionTest(t, inviter.Id)
	require.Equal(t, 1000, inviter.Quota)
	require.Equal(t, 1000, inviter.AffHistoryQuota)
}

func TestSettleAffDailyCommissionForDateZeroPercent(t *testing.T) {
	setupAffDailyCommissionTestDB(t)
	common.AffCommissionPercentage = 1

	inviter := createAffDailyCommissionUser(t, User{
		Username:             "zero-inviter",
		Password:             "password123",
		AffCode:              "aff-zero-inviter",
		AffCommissionPercent: -1,
	})
	invitee := createAffDailyCommissionUser(t, User{
		Username:  "zero-invitee",
		Password:  "password123",
		AffCode:   "aff-zero-invitee",
		InviterId: inviter.Id,
	})
	require.NoError(t, DB.Exec("UPDATE users SET aff_commission_percent = 0 WHERE id = ?", inviter.Id).Error)
	targetDate := time.Date(2026, 4, 5, 0, 0, 0, 0, time.Local)
	createConsumeLogForDate(t, invitee.Id, 5000, targetDate)

	summary, err := SettleAffDailyCommissionForDate(targetDate)
	require.NoError(t, err)
	require.Equal(t, 1, summary.SettledCount)
	require.Equal(t, 0, summary.RewardedCount)
	require.EqualValues(t, 0, summary.CommissionQuota)

	inviter = fetchUserForAffDailyCommissionTest(t, inviter.Id)
	require.Equal(t, 0, inviter.Quota)
	require.Equal(t, 0, inviter.AffHistoryQuota)

	var settlement AffDailyCommissionSettlement
	require.NoError(t, DB.Where("invitee_id = ? AND settle_date = ?", invitee.Id, "2026-04-05").First(&settlement).Error)
	require.Equal(t, 0, settlement.CommissionPercent)
	require.Equal(t, 0, settlement.CommissionQuota)
}

func TestSettleAffDailyCommissionForDateIdempotent(t *testing.T) {
	setupAffDailyCommissionTestDB(t)
	common.AffCommissionPercentage = 10

	inviter := createAffDailyCommissionUser(t, User{
		Username:             "idempotent-inviter",
		Password:             "password123",
		AffCode:              "aff-idempotent-inviter",
		AffCommissionPercent: -1,
	})
	invitee := createAffDailyCommissionUser(t, User{
		Username:  "idempotent-invitee",
		Password:  "password123",
		AffCode:   "aff-idempotent-invitee",
		InviterId: inviter.Id,
	})
	targetDate := time.Date(2026, 4, 5, 0, 0, 0, 0, time.Local)
	createConsumeLogForDate(t, invitee.Id, 1234, targetDate)

	firstSummary, err := SettleAffDailyCommissionForDate(targetDate)
	require.NoError(t, err)
	require.EqualValues(t, 123, firstSummary.CommissionQuota)

	secondSummary, err := SettleAffDailyCommissionForDate(targetDate)
	require.NoError(t, err)
	require.Equal(t, 0, secondSummary.SettledCount)
	require.Equal(t, 0, secondSummary.RewardedCount)
	require.EqualValues(t, 0, secondSummary.CommissionQuota)

	inviter = fetchUserForAffDailyCommissionTest(t, inviter.Id)
	require.Equal(t, 123, inviter.Quota)
	require.Equal(t, 123, inviter.AffHistoryQuota)

	var count int64
	require.NoError(t, DB.Model(&AffDailyCommissionSettlement{}).Where("invitee_id = ? AND settle_date = ?", invitee.Id, "2026-04-05").Count(&count).Error)
	require.EqualValues(t, 1, count)
}
