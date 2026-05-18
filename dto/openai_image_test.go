package dto

import (
	"encoding/json"
	"testing"
)

func TestImageRequestKeepsGPTImage2CompatibleFields(t *testing.T) {
	raw := []byte(`{
		"model": "gpt-image-2",
		"prompt": "make a poster",
		"count": 3,
		"async": true,
		"image": "https://example.com/ref.png",
		"images": ["https://example.com/a.png", "https://example.com/b.png"],
		"ref_assets": ["asset-1"],
		"mask": "data:image/png;base64,AAAA",
		"response_format": "url"
	}`)

	var req ImageRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		t.Fatalf("unmarshal image request: %v", err)
	}

	if req.GetImageCount() != 3 {
		t.Fatalf("expected count 3, got %d", req.GetImageCount())
	}

	encoded, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal image request: %v", err)
	}

	var out map[string]any
	if err := json.Unmarshal(encoded, &out); err != nil {
		t.Fatalf("unmarshal marshaled request: %v", err)
	}

	for _, field := range []string{"model", "prompt", "count", "async", "image", "images", "ref_assets", "mask", "response_format"} {
		if _, ok := out[field]; !ok {
			t.Fatalf("expected marshaled request to contain %q; body=%s", field, string(encoded))
		}
	}
}
