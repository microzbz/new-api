package service

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestNextAffDailyCommissionRunTimeBeforeTwoAM(t *testing.T) {
	now := time.Date(2026, 4, 11, 1, 30, 0, 0, time.Local)

	nextRun := nextAffDailyCommissionRunTime(now)

	require.Equal(t, time.Date(2026, 4, 11, 2, 0, 0, 0, time.Local), nextRun)
}

func TestNextAffDailyCommissionRunTimeAtOrAfterTwoAM(t *testing.T) {
	now := time.Date(2026, 4, 11, 2, 0, 0, 0, time.Local)

	nextRun := nextAffDailyCommissionRunTime(now)

	require.Equal(t, time.Date(2026, 4, 12, 2, 0, 0, 0, time.Local), nextRun)
}
