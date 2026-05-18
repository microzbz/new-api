package openai

import (
	"mime/multipart"
	"testing"
)

func TestCollectImageFilePartsSupportsCompatibleFields(t *testing.T) {
	files := map[string][]*multipart.FileHeader{
		"image":      {&multipart.FileHeader{Filename: "image.png"}},
		"images":     {&multipart.FileHeader{Filename: "ref-1.png"}, &multipart.FileHeader{Filename: "ref-2.png"}},
		"ref_assets": {&multipart.FileHeader{Filename: "asset.png"}},
	}

	parts := collectImageFileParts(files)
	if len(parts) != 4 {
		t.Fatalf("expected 4 image parts, got %d", len(parts))
	}

	fields := make(map[string]int)
	for _, part := range parts {
		fields[part.field]++
	}

	if fields["image"] != 1 {
		t.Fatalf("expected one image field, got %d", fields["image"])
	}
	if fields["images"] != 2 {
		t.Fatalf("expected two images fields, got %d", fields["images"])
	}
	if fields["ref_assets"] != 1 {
		t.Fatalf("expected one ref_assets field, got %d", fields["ref_assets"])
	}
}

func TestCollectImageFilePartsDoesNotDuplicateBracketFields(t *testing.T) {
	files := map[string][]*multipart.FileHeader{
		"images[]": {&multipart.FileHeader{Filename: "ref.png"}},
	}

	parts := collectImageFileParts(files)
	if len(parts) != 1 {
		t.Fatalf("expected 1 image part, got %d", len(parts))
	}
	if parts[0].field != "images[]" {
		t.Fatalf("expected images[] field, got %q", parts[0].field)
	}
}
