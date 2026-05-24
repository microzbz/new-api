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

func TestInsertCountsInviteWhenInviterRewardIsZero(t *testing.T) {
	setupAffDailyCommissionTestDB(t)

	oldQuotaForInviter := common.QuotaForInviter
	oldQuotaForInvitee := common.QuotaForInvitee
	oldQuotaForNewUser := common.QuotaForNewUser
	t.Cleanup(func() {
		common.QuotaForInviter = oldQuotaForInviter
		common.QuotaForInvitee = oldQuotaForInvitee
		common.QuotaForNewUser = oldQuotaForNewUser
	})
	common.QuotaForInviter = 0
	common.QuotaForInvitee = 0
	common.QuotaForNewUser = 0

	inviter := createAffDailyCommissionUser(t, User{
		Username: "zero-reward-count-inviter",
		Password: "password123",
		AffCode:  "aff-zero-reward-count",
	})
	invitee := User{
		Username:             "zero-reward-count-invitee",
		Password:             "password123",
		InviterId:            inviter.Id,
		AffCommissionPercent: -1,
	}
	require.NoError(t, invitee.Insert(inviter.Id))

	inviter = fetchUserForAffDailyCommissionTest(t, inviter.Id)
	require.Equal(t, 1, inviter.AffCount)

	count, err := CountInvitedUsers(inviter.Id)
	require.NoError(t, err)
	require.EqualValues(t, 1, count)
}

func TestGetInvitedUserSummaries(t *testing.T) {
	setupAffDailyCommissionTestDB(t)

	inviter := createAffDailyCommissionUser(t, User{
		Username: "summary-inviter",
		Password: "password123",
		AffCode:  "aff-summary-inviter",
	})
	otherInviter := createAffDailyCommissionUser(t, User{
		Username: "summary-other-inviter",
		Password: "password123",
		AffCode:  "aff-summary-other",
	})
	inviteeA := createAffDailyCommissionUser(t, User{
		Username:     "summary-invitee-a",
		DisplayName:  "Invitee A",
		Password:     "password123",
		AffCode:      "aff-summary-a",
		InviterId:    inviter.Id,
		Quota:        1200,
		UsedQuota:    300,
		RequestCount: 7,
	})
	inviteeB := createAffDailyCommissionUser(t, User{
		Username:  "summary-invitee-b",
		Password:  "password123",
		AffCode:   "aff-summary-b",
		InviterId: inviter.Id,
		Quota:     500,
	})

	settlements := []AffDailyCommissionSettlement{
		{
			InviteeId:         inviteeA.Id,
			InviterId:         inviter.Id,
			SettleDate:        "2026-04-01",
			StartTimestamp:    1,
			EndTimestamp:      2,
			ConsumedQuota:     1000,
			CommissionPercent: 1,
			CommissionQuota:   10,
			CreatedAt:         3,
		},
		{
			InviteeId:         inviteeA.Id,
			InviterId:         inviter.Id,
			SettleDate:        "2026-04-02",
			StartTimestamp:    4,
			EndTimestamp:      5,
			ConsumedQuota:     2000,
			CommissionPercent: 1,
			CommissionQuota:   20,
			CreatedAt:         6,
		},
		{
			InviteeId:         inviteeB.Id,
			InviterId:         otherInviter.Id,
			SettleDate:        "2026-04-01",
			StartTimestamp:    1,
			EndTimestamp:      2,
			ConsumedQuota:     9999,
			CommissionPercent: 1,
			CommissionQuota:   99,
			CreatedAt:         3,
		},
	}
	require.NoError(t, DB.Create(&settlements).Error)

	summaries, total, err := GetInvitedUserSummaries(inviter.Id, 0, 10)
	require.NoError(t, err)
	require.EqualValues(t, 2, total)
	require.Len(t, summaries, 2)

	byId := map[int]InvitedUserSummary{}
	for _, summary := range summaries {
		byId[summary.Id] = summary
	}

	require.Equal(t, "summary-invitee-a", byId[inviteeA.Id].Username)
	require.Equal(t, "Invitee A", byId[inviteeA.Id].DisplayName)
	require.Equal(t, 1200, byId[inviteeA.Id].Quota)
	require.Equal(t, 300, byId[inviteeA.Id].UsedQuota)
	require.Equal(t, 7, byId[inviteeA.Id].RequestCount)
	require.EqualValues(t, 3000, byId[inviteeA.Id].ConsumedQuota)
	require.EqualValues(t, 30, byId[inviteeA.Id].CommissionQuota)
	require.EqualValues(t, 0, byId[inviteeB.Id].ConsumedQuota)
	require.EqualValues(t, 0, byId[inviteeB.Id].CommissionQuota)
}
