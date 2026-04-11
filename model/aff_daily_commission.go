package model

import (
	"fmt"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/logger"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type AffDailyCommissionSettlement struct {
	Id                int    `json:"id"`
	InviteeId         int    `json:"invitee_id" gorm:"not null;uniqueIndex:idx_aff_daily_invitee_date"`
	InviterId         int    `json:"inviter_id" gorm:"not null;default:0;index"`
	SettleDate        string `json:"settle_date" gorm:"type:varchar(10);not null;uniqueIndex:idx_aff_daily_invitee_date"`
	StartTimestamp    int64  `json:"start_timestamp" gorm:"not null"`
	EndTimestamp      int64  `json:"end_timestamp" gorm:"not null"`
	ConsumedQuota     int    `json:"consumed_quota" gorm:"not null;default:0"`
	CommissionPercent int    `json:"commission_percent" gorm:"not null;default:0"`
	CommissionQuota   int    `json:"commission_quota" gorm:"not null;default:0"`
	CreatedAt         int64  `json:"created_at" gorm:"not null;index"`
}

type AffDailyCommissionSettlementSummary struct {
	SettleDate      string
	InviteeCount    int
	SettledCount    int
	RewardedCount   int
	ConsumedQuota   int64
	CommissionQuota int64
}

type affDailyCommissionUsage struct {
	UserId        int   `json:"user_id"`
	ConsumedQuota int64 `json:"consumed_quota"`
}

func normalizeAffDailySettleWindow(targetDate time.Time) (string, int64, int64) {
	localDate := targetDate.In(time.Local)
	dayStart := time.Date(localDate.Year(), localDate.Month(), localDate.Day(), 0, 0, 0, 0, time.Local)
	dayEnd := dayStart.AddDate(0, 0, 1)
	return dayStart.Format("2006-01-02"), dayStart.Unix(), dayEnd.Unix()
}

func SettleAffDailyCommissionForDate(targetDate time.Time) (AffDailyCommissionSettlementSummary, error) {
	summary := AffDailyCommissionSettlementSummary{}
	if DB == nil || LOG_DB == nil {
		return summary, fmt.Errorf("database not initialized")
	}

	settleDate, startTimestamp, endTimestamp := normalizeAffDailySettleWindow(targetDate)
	summary.SettleDate = settleDate

	var usages []affDailyCommissionUsage
	err := LOG_DB.Model(&Log{}).
		Select("user_id, SUM(quota) AS consumed_quota").
		Where("type = ? AND created_at >= ? AND created_at < ? AND quota > ?", LogTypeConsume, startTimestamp, endTimestamp, 0).
		Group("user_id").
		Scan(&usages).Error
	if err != nil {
		return summary, err
	}

	summary.InviteeCount = len(usages)
	for _, usage := range usages {
		if usage.UserId == 0 || usage.ConsumedQuota <= 0 {
			continue
		}
		reward, settled, err := settleAffDailyCommissionForInvitee(settleDate, startTimestamp, endTimestamp, usage.UserId, int(usage.ConsumedQuota))
		if err != nil {
			return summary, err
		}
		if !settled {
			continue
		}
		summary.SettledCount++
		summary.ConsumedQuota += usage.ConsumedQuota
		if reward.Quota > 0 {
			summary.RewardedCount++
			summary.CommissionQuota += int64(reward.Quota)
		}
	}
	return summary, nil
}

func settleAffDailyCommissionForInvitee(settleDate string, startTimestamp int64, endTimestamp int64, inviteeUserId int, consumedQuota int) (AffCommissionReward, bool, error) {
	reward := AffCommissionReward{}
	if inviteeUserId == 0 || consumedQuota <= 0 {
		return reward, false, nil
	}

	settled := false
	err := DB.Transaction(func(tx *gorm.DB) error {
		var err error
		reward, err = buildInviterCommissionRewardTx(tx, inviteeUserId, consumedQuota)
		if err != nil {
			return err
		}

		settlement := AffDailyCommissionSettlement{
			InviteeId:         inviteeUserId,
			InviterId:         reward.InviterId,
			SettleDate:        settleDate,
			StartTimestamp:    startTimestamp,
			EndTimestamp:      endTimestamp,
			ConsumedQuota:     consumedQuota,
			CommissionPercent: reward.Percent,
			CommissionQuota:   reward.Quota,
			CreatedAt:         common.GetTimestamp(),
		}

		result := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&settlement)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 0 {
			return nil
		}

		settled = true
		return grantInviterCommissionRewardTx(tx, reward)
	})
	if err != nil {
		return reward, false, err
	}
	if !settled {
		return reward, false, nil
	}
	if reward.Quota > 0 {
		if err := invalidateUserCache(reward.InviterId); err != nil {
			common.SysLog("failed to invalidate inviter cache after daily commission settlement: " + err.Error())
		}
		RecordLog(reward.InviterId, LogTypeSystem, fmt.Sprintf("邀请用户日消耗返佣 %s（用户ID:%d，结算日:%s，比例:%d%%）", logger.LogQuota(reward.Quota), inviteeUserId, settleDate, reward.Percent))
	}
	return reward, true, nil
}
