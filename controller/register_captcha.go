package controller

import (
	"bytes"
	crand "crypto/rand"
	"encoding/base64"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"math/big"
	"math/rand"
	"strconv"
	"strings"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/gin-contrib/sessions"
	"github.com/gin-gonic/gin"
	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

const (
	registerCaptchaSessionKey       = "register_captcha_code"
	registerCaptchaExpireSessionKey = "register_captcha_expire_at"
	registerCaptchaLength           = 4
	registerCaptchaTTL              = 5 * time.Minute
)

func GetRegisterCaptcha(c *gin.Context) {
	imageBase64, answer, err := buildRegisterCaptcha()
	if err != nil {
		common.ApiError(c, err)
		return
	}

	session := sessions.Default(c)
	session.Set(registerCaptchaSessionKey, answer)
	session.Set(registerCaptchaExpireSessionKey, time.Now().Add(registerCaptchaTTL).Unix())
	if err := session.Save(); err != nil {
		common.ApiErrorMsg(c, "无法保存验证码会话，请重试")
		return
	}

	common.ApiSuccess(c, gin.H{
		"image":      "data:image/png;base64," + imageBase64,
		"expires_in": int(registerCaptchaTTL.Seconds()),
	})
}

func verifyRegisterCaptcha(c *gin.Context, input string) error {
	if strings.TrimSpace(input) == "" {
		return fmt.Errorf("请输入图形验证码")
	}

	session := sessions.Default(c)
	expected := strings.ToUpper(strings.TrimSpace(common.Interface2String(session.Get(registerCaptchaSessionKey))))
	expireAt := sessionInt64(session.Get(registerCaptchaExpireSessionKey))
	now := time.Now().Unix()

	clearCaptcha := func() {
		session.Delete(registerCaptchaSessionKey)
		session.Delete(registerCaptchaExpireSessionKey)
		_ = session.Save()
	}

	if expected == "" || expireAt == 0 || now > expireAt {
		clearCaptcha()
		return fmt.Errorf("图形验证码已过期，请刷新后重试")
	}

	if strings.ToUpper(strings.TrimSpace(input)) != expected {
		clearCaptcha()
		return fmt.Errorf("图形验证码错误，请重新输入")
	}

	clearCaptcha()
	return nil
}

func sessionInt64(v any) int64 {
	switch value := v.(type) {
	case int64:
		return value
	case int:
		return int64(value)
	case int32:
		return int64(value)
	case float64:
		return int64(value)
	case string:
		parsed, _ := strconv.ParseInt(value, 10, 64)
		return parsed
	default:
		return 0
	}
}

func buildRegisterCaptcha() (string, string, error) {
	code, err := generateRegisterCaptchaCode(registerCaptchaLength)
	if err != nil {
		return "", "", err
	}

	img := image.NewRGBA(image.Rect(0, 0, 132, 44))
	draw.Draw(img, img.Bounds(), &image.Uniform{C: color.RGBA{245, 247, 250, 255}}, image.Point{}, draw.Src)

	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	for i := 0; i < 8; i++ {
		drawNoiseLine(img, rng)
	}
	for i := 0; i < 90; i++ {
		x := rng.Intn(img.Bounds().Dx())
		y := rng.Intn(img.Bounds().Dy())
		img.Set(x, y, randomColor(rng, 90, 180))
	}

	face := basicfont.Face7x13
	for i, ch := range code {
		drawChar(img, face, string(ch), 14+i*28+rng.Intn(4), 28+rng.Intn(8), randomColor(rng, 20, 140))
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return "", "", err
	}

	return base64.StdEncoding.EncodeToString(buf.Bytes()), code, nil
}

func generateRegisterCaptchaCode(length int) (string, error) {
	const charset = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
	var builder strings.Builder
	builder.Grow(length)
	for i := 0; i < length; i++ {
		n, err := crand.Int(crand.Reader, big.NewInt(int64(len(charset))))
		if err != nil {
			return "", err
		}
		builder.WriteByte(charset[n.Int64()])
	}
	return builder.String(), nil
}

func drawNoiseLine(img *image.RGBA, rng *rand.Rand) {
	width := img.Bounds().Dx()
	height := img.Bounds().Dy()
	x1, y1 := rng.Intn(width), rng.Intn(height)
	x2, y2 := rng.Intn(width), rng.Intn(height)
	clr := randomColor(rng, 120, 210)

	dx := absInt(x2 - x1)
	dy := absInt(y2 - y1)
	sx := -1
	if x1 < x2 {
		sx = 1
	}
	sy := -1
	if y1 < y2 {
		sy = 1
	}
	errVal := dx - dy

	for {
		if image.Pt(x1, y1).In(img.Bounds()) {
			img.Set(x1, y1, clr)
		}
		if x1 == x2 && y1 == y2 {
			break
		}
		e2 := 2 * errVal
		if e2 > -dy {
			errVal -= dy
			x1 += sx
		}
		if e2 < dx {
			errVal += dx
			y1 += sy
		}
	}
}

func drawChar(img draw.Image, face font.Face, value string, x int, y int, clr color.Color) {
	d := &font.Drawer{
		Dst:  img,
		Src:  image.NewUniform(clr),
		Face: face,
		Dot:  fixed.P(x, y),
	}
	d.DrawString(value)
}

func randomColor(rng *rand.Rand, min int, max int) color.RGBA {
	if max <= min {
		max = min + 1
	}
	return color.RGBA{
		R: uint8(min + rng.Intn(max-min)),
		G: uint8(min + rng.Intn(max-min)),
		B: uint8(min + rng.Intn(max-min)),
		A: 255,
	}
}

func absInt(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
