package service

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/logger"
	"github.com/QuantumNous/new-api/model"

	"github.com/bytedance/gopkg/util/gopool"
)

const affDailyCommissionRunHour = 2

var (
	affDailyCommissionOnce    sync.Once
	affDailyCommissionRunning atomic.Bool
)

func StartAffDailyCommissionSettlementTask() {
	affDailyCommissionOnce.Do(func() {
		if !common.IsMasterNode {
			return
		}
		gopool.Go(func() {
			ctx := context.Background()
			logger.LogInfo(ctx, fmt.Sprintf(
				"aff daily commission task started: schedule=daily %02d:00 (%s)",
				affDailyCommissionRunHour,
				time.Now().In(time.Local).Location().String(),
			))
			for {
				now := time.Now().In(time.Local)
				nextRun := nextAffDailyCommissionRunTime(now)
				waitDuration := time.Until(nextRun)
				logger.LogInfo(ctx, fmt.Sprintf(
					"aff daily commission next run scheduled at %s (in %s)",
					nextRun.Format(time.RFC3339),
					waitDuration.Truncate(time.Second),
				))
				timer := time.NewTimer(waitDuration)
				<-timer.C
				if _, err := RunAffDailyCommissionSettlementForYesterday(ctx, "scheduled"); err != nil {
					logger.LogWarn(ctx, fmt.Sprintf("aff daily commission scheduled run failed: %v", err))
				}
			}
		})
	})
}

func RunAffDailyCommissionSettlementForYesterday(ctx context.Context, trigger string) (model.AffDailyCommissionSettlementSummary, error) {
	targetDate := time.Now().In(time.Local).AddDate(0, 0, -1)
	return RunAffDailyCommissionSettlementForDate(ctx, targetDate, trigger)
}

func RunAffDailyCommissionSettlementForDate(ctx context.Context, targetDate time.Time, trigger string) (model.AffDailyCommissionSettlementSummary, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if !affDailyCommissionRunning.CompareAndSwap(false, true) {
		return model.AffDailyCommissionSettlementSummary{}, errors.New("aff daily commission settlement is already running")
	}
	defer affDailyCommissionRunning.Store(false)

	summary, err := model.SettleAffDailyCommissionForDate(targetDate)
	if err != nil {
		logger.LogWarn(ctx, fmt.Sprintf("aff daily commission settlement failed: trigger=%s, date=%s, err=%v", trigger, targetDate.In(time.Local).Format("2006-01-02"), err))
		return summary, err
	}
	shouldLog := summary.SettledCount > 0 || common.DebugEnabled || trigger != "scheduled"
	if shouldLog {
		logger.LogInfo(ctx, fmt.Sprintf(
			"aff daily commission settled: trigger=%s, date=%s, invitees=%d, settled=%d, rewarded=%d, consumed_quota=%d, commission_quota=%d",
			trigger,
			summary.SettleDate,
			summary.InviteeCount,
			summary.SettledCount,
			summary.RewardedCount,
			summary.ConsumedQuota,
			summary.CommissionQuota,
		))
	}
	return summary, nil
}

func nextAffDailyCommissionRunTime(now time.Time) time.Time {
	localNow := now.In(time.Local)
	nextRun := time.Date(
		localNow.Year(),
		localNow.Month(),
		localNow.Day(),
		affDailyCommissionRunHour,
		0,
		0,
		0,
		time.Local,
	)
	if !localNow.Before(nextRun) {
		nextRun = nextRun.AddDate(0, 0, 1)
	}
	return nextRun
}
