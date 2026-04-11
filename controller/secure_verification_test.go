package controller

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/middleware"
	"github.com/QuantumNous/new-api/model"
	"github.com/gin-contrib/sessions"
	"github.com/gin-contrib/sessions/cookie"
	"github.com/gin-gonic/gin"
)

func seedUser(t *testing.T, userID int, username string, password string) *model.User {
	t.Helper()

	passwordHash, err := common.Password2Hash(password)
	if err != nil {
		t.Fatalf("failed to hash password: %v", err)
	}

	user := &model.User{
		Id:       userID,
		Username: username,
		Password: passwordHash,
		Role:     common.RoleCommonUser,
		Status:   common.UserStatusEnabled,
		Group:    "default",
	}
	if err := model.DB.Create(user).Error; err != nil {
		t.Fatalf("failed to create user: %v", err)
	}
	return user
}

func newSecureVerificationTestRouter(userID int) *gin.Engine {
	router := gin.New()
	store := cookie.NewStore([]byte("secure-verification-test"))
	router.Use(sessions.Sessions("test-session", store))
	router.Use(func(c *gin.Context) {
		c.Set("id", userID)
		c.Next()
	})
	router.POST("/api/verify", UniversalVerify)
	router.POST("/api/token/:id/key", middleware.SecureVerificationRequiredWithMethods("password"), GetTokenKey)
	router.POST("/test/session/:method", func(c *gin.Context) {
		session := sessions.Default(c)
		session.Set(SecureVerificationSessionKey, time.Now().Unix())
		session.Set(SecureVerificationMethodSessionKey, c.Param("method"))
		if err := session.Save(); err != nil {
			c.String(http.StatusInternalServerError, err.Error())
			return
		}
		c.Status(http.StatusNoContent)
	})
	return router
}

func addCookies(req *http.Request, recorder *httptest.ResponseRecorder) {
	for _, cookie := range recorder.Result().Cookies() {
		req.AddCookie(cookie)
	}
}

func TestUniversalVerifyPasswordAllowsTokenKeyAccess(t *testing.T) {
	setupTokenControllerTestDB(t)
	user := seedUser(t, 1, "secure-user", "super-secret-password")
	token := seedToken(t, model.DB, user.Id, "owned-token", "secure1234token5678")
	router := newSecureVerificationTestRouter(user.Id)

	verifyReq := httptest.NewRequest(http.MethodPost, "/api/verify", strings.NewReader(`{"method":"password","code":"super-secret-password"}`))
	verifyReq.Header.Set("Content-Type", "application/json")
	verifyRecorder := httptest.NewRecorder()
	router.ServeHTTP(verifyRecorder, verifyReq)

	verifyResponse := decodeAPIResponse(t, verifyRecorder)
	if !verifyResponse.Success {
		t.Fatalf("expected password verification to succeed, got message: %s", verifyResponse.Message)
	}

	keyReq := httptest.NewRequest(http.MethodPost, "/api/token/"+strconv.Itoa(token.Id)+"/key", nil)
	addCookies(keyReq, verifyRecorder)
	keyRecorder := httptest.NewRecorder()
	router.ServeHTTP(keyRecorder, keyReq)

	keyResponse := decodeAPIResponse(t, keyRecorder)
	if !keyResponse.Success {
		t.Fatalf("expected verified token key fetch to succeed, got message: %s", keyResponse.Message)
	}

	var keyData tokenKeyResponse
	if err := common.Unmarshal(keyResponse.Data, &keyData); err != nil {
		t.Fatalf("failed to decode token key response: %v", err)
	}
	if keyData.Key != token.GetFullKey() {
		t.Fatalf("expected full key %q, got %q", token.GetFullKey(), keyData.Key)
	}
}

func TestTokenKeyRouteRequiresPasswordVerification(t *testing.T) {
	setupTokenControllerTestDB(t)
	user := seedUser(t, 1, "secure-user", "super-secret-password")
	token := seedToken(t, model.DB, user.Id, "owned-token", "secure1234token5678")
	router := newSecureVerificationTestRouter(user.Id)

	keyReq := httptest.NewRequest(http.MethodPost, "/api/token/"+strconv.Itoa(token.Id)+"/key", nil)
	keyRecorder := httptest.NewRecorder()
	router.ServeHTTP(keyRecorder, keyReq)

	if keyRecorder.Code != http.StatusForbidden {
		t.Fatalf("expected 403 without verification, got %d", keyRecorder.Code)
	}

	response := decodeAPIResponse(t, keyRecorder)
	if response.Success {
		t.Fatalf("expected unverified token key fetch to fail")
	}
	if !strings.Contains(keyRecorder.Body.String(), "VERIFICATION_REQUIRED") {
		t.Fatalf("expected verification required code, got body: %s", keyRecorder.Body.String())
	}
}

func TestTokenKeyRouteRejectsWrongVerificationMethod(t *testing.T) {
	setupTokenControllerTestDB(t)
	user := seedUser(t, 1, "secure-user", "super-secret-password")
	token := seedToken(t, model.DB, user.Id, "owned-token", "secure1234token5678")
	router := newSecureVerificationTestRouter(user.Id)

	sessionReq := httptest.NewRequest(http.MethodPost, "/test/session/2fa", nil)
	sessionRecorder := httptest.NewRecorder()
	router.ServeHTTP(sessionRecorder, sessionReq)

	keyReq := httptest.NewRequest(http.MethodPost, "/api/token/"+strconv.Itoa(token.Id)+"/key", nil)
	addCookies(keyReq, sessionRecorder)
	keyRecorder := httptest.NewRecorder()
	router.ServeHTTP(keyRecorder, keyReq)

	if keyRecorder.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for wrong verification method, got %d", keyRecorder.Code)
	}

	response := decodeAPIResponse(t, keyRecorder)
	if response.Success {
		t.Fatalf("expected token key fetch with wrong verification method to fail")
	}
	if !strings.Contains(keyRecorder.Body.String(), "VERIFICATION_METHOD_REQUIRED") {
		t.Fatalf("expected verification method required code, got body: %s", keyRecorder.Body.String())
	}
}
