package common

import "testing"

func TestIsImageGenerationModelMatchesGPTImagePrefix(t *testing.T) {
	for _, modelName := range []string{"gpt-image-1", "gpt-image-1.5", "gpt-image-2", "gpt-image-2-2026-04-21"} {
		if !IsImageGenerationModel(modelName) {
			t.Fatalf("expected %q to be treated as an image generation model", modelName)
		}
	}
}
