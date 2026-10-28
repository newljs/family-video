package family

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type videoMetadata struct {
	SourceID    string `json:"source_id,omitempty"`
	Title       string `json:"title"`
	Description string `json:"description"`
}

func clipped(s string, limit int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) > limit {
		r = r[:limit]
	}
	return string(r)
}

// Remove share transport text, while preserving the actual creator caption.
func shareMetadata(text string) videoMetadata {
	text = strings.ReplaceAll(text, `\:`, ":")
	text = shareURL.ReplaceAllString(text, "")
	if i := strings.Index(text, "的作品】"); i >= 0 {
		text = text[i+len("的作品】"):]
	} else {
		for _, marker := range []string{"复制打开抖音极速版，", "复制打开抖音，", "复制打开抖音极速版", "复制打开抖音"} {
			if i := strings.Index(text, marker); i >= 0 {
				text = text[i+len(marker):]
				break
			}
		}
	}
	text = strings.TrimSpace(text)
	if strings.HasPrefix(text, "看看【") {
		text = ""
	}
	text = regexp.MustCompile(`\s+`).ReplaceAllString(text, " ")
	text = strings.Trim(text, " ，。；/ ")
	return videoMetadata{Title: clipped(strings.Split(text, "\n")[0], 80), Description: clipped(text, 4000)}
}

func readMetadata(folder string) videoMetadata {
	var m videoMetadata
	raw, _ := os.ReadFile(filepath.Join(folder, "metadata.json"))
	json.Unmarshal(raw, &m)
	return m
}
func writeMetadata(folder string, m videoMetadata) {
	raw, _ := json.Marshal(m)
	os.WriteFile(filepath.Join(folder, "metadata.json"), raw, 0600)
}
func automaticTitle(title string) bool {
	return title == "" || title == "新收集的视频" || title == "本地视频"
}

func chooseMetadata(title string, manual bool, share string, platform videoMetadata, p probe) videoMetadata {
	shared := shareMetadata(share)
	tags := p.Format.Tags
	embedded := videoMetadata{Title: tags["title"], Description: tags["description"]}
	if embedded.Description == "" {
		embedded.Description = tags["comment"]
	}
	result := videoMetadata{Title: title}
	if !manual {
		for _, candidate := range []string{platform.Title, embedded.Title, shared.Title, title} {
			if strings.TrimSpace(candidate) != "" {
				result.Title = clipped(candidate, 200)
				break
			}
		}
	}
	for _, candidate := range []string{platform.Description, platform.Title, embedded.Description, shared.Description} {
		if strings.TrimSpace(candidate) != "" {
			result.Description = clipped(candidate, 4000)
			break
		}
	}
	if result.Title == "" {
		result.Title = "家庭精选视频"
	}
	return result
}
