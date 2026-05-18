package controller

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/gin-contrib/sessions"
	"github.com/gin-contrib/sessions/cookie"
	"github.com/gin-gonic/gin"
)

func newRegisterTestRouter() *gin.Engine {
	router := gin.New()
	store := cookie.NewStore([]byte("register-captcha-test"))
	router.Use(sessions.Sessions("register-test-session", store))
	router.GET("/api/user/register/captcha", GetRegisterCaptcha)
	router.POST("/api/user/register", Register)
	return router
}

func TestGetRegisterCaptchaStoresSessionAndReturnsImage(t *testing.T) {
	router := newRegisterTestRouter()

	req := httptest.NewRequest(http.MethodGet, "/api/user/register/captcha", nil)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	response := decodeAPIResponse(t, recorder)
	if !response.Success {
		t.Fatalf("expected success response, got message: %s", response.Message)
	}
	if !strings.Contains(recorder.Body.String(), "data:image/png;base64,") {
		t.Fatalf("expected captcha image payload, got body: %s", recorder.Body.String())
	}
}

func TestRegisterRejectsWrongCaptcha(t *testing.T) {
	setupTokenControllerTestDB(t)
	common.RegisterEnabled = true
	common.PasswordRegisterEnabled = true
	common.EmailVerificationEnabled = false

	router := newRegisterTestRouter()

	captchaReq := httptest.NewRequest(http.MethodGet, "/api/user/register/captcha", nil)
	captchaRecorder := httptest.NewRecorder()
	router.ServeHTTP(captchaRecorder, captchaReq)

	registerReq := httptest.NewRequest(http.MethodPost, "/api/user/register", strings.NewReader(`{"username":"captcha-user","password":"password88","captcha_code":"WRONG"}`))
	registerReq.Header.Set("Content-Type", "application/json")
	addCookies(registerReq, captchaRecorder)
	registerRecorder := httptest.NewRecorder()
	router.ServeHTTP(registerRecorder, registerReq)

	response := decodeAPIResponse(t, registerRecorder)
	if response.Success {
		t.Fatalf("expected register to fail with wrong captcha")
	}
	if !strings.Contains(response.Message, "图形验证码错误") {
		t.Fatalf("expected captcha error, got message: %s", response.Message)
	}

	var count int64
	if err := model.DB.Model(&model.User{}).Where("username = ?", "captcha-user").Count(&count).Error; err != nil {
		t.Fatalf("failed to count users: %v", err)
	}
	if count != 0 {
		t.Fatalf("expected no user to be created, got %d", count)
	}
}
