package family

// Web 管理台的资源库分页列表、分类与话题标签筛选。
// 分类由标题/描述关键词规则归纳，标签取自 #话题 文本；均不落库，
// 每次请求基于现有数据即时计算（本地库规模下开销可忽略）。

import (
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// hashtag 提取：# 或全角 ＃ 后的非空白连续片段，容忍尾部分隔符。
var hashtagPattern = regexp.MustCompile(`[#＃]([^\s#＃，。,.;；:：！!？?、""]{1,30})`)

type categoryRule struct {
	Name     string
	Keywords []string
}

// 分类体系：按家庭儿童内容库归纳，顺序即优先级（先匹配先归类）。
var categoryRules = []categoryRule{
	{"英语启蒙", []string{"英语", "英文", "单词", "音标", "口语", "听力", "自然拼读", "分级阅读"}},
	{"语文古诗", []string{"语文", "古诗", "诗词", "拼音", "识字", "阅读理解", "作文", "成语"}},
	{"数学思维", []string{"数学", "口算", "奥数", "加减", "乘法", "除法", "几何", "思维"}},
	{"历史人文", []string{"历史", "朝代", "近代史", "国耻", "文物", "典故", "国学"}},
	{"科普百科", []string{"科学", "科普", "实验", "动物", "植物", "宇宙", "恐龙", "地理", "百科"}},
	{"动画故事", []string{"动画", "故事", "绘本", "动画片", "童话"}},
	{"儿歌音乐", []string{"儿歌", "歌曲", "音乐", "唱歌", "律动", "跳舞"}},
	{"生活习惯", []string{"习惯", "安全", "健康", "洗手", "自理", "礼仪"}},
	{"家庭教育", []string{"家长", "家庭教育", "育儿", "学习方法", "涨知识", "知识分享"}},
}

// classify 按规则优先级返回首个命中的分类，未命中归入未分类。
func classify(title, description string) string {
	text := strings.ToLower(title + " " + description)
	for _, rule := range categoryRules {
		for _, keyword := range rule.Keywords {
			if strings.Contains(text, strings.ToLower(keyword)) {
				return rule.Name
			}
		}
	}
	return "未分类"
}

func extractHashtags(title, description string) []string {
	seen := map[string]bool{}
	tags := []string{}
	for _, match := range hashtagPattern.FindAllStringSubmatch(title+" "+description, -1) {
		tag := strings.Trim(match[1], "-·.、")
		if tag == "" || seen[tag] {
			continue
		}
		seen[tag] = true
		tags = append(tags, tag)
	}
	return tags
}

type countItem struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}

func sortedCounts(counts map[string]int) []countItem {
	items := make([]countItem, 0, len(counts))
	for name, count := range counts {
		items = append(items, countItem{name, count})
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].Count != items[j].Count {
			return items[i].Count > items[j].Count
		}
		return items[i].Name < items[j].Name
	})
	return items
}

func (a *App) libraryMeta(w http.ResponseWriter, r *http.Request, _ string) error {
	items, err := query(a.DB, "SELECT title, description FROM videos")
	if err != nil {
		return err
	}
	categoryCounts := map[string]int{}
	tagCounts := map[string]int{}
	for _, item := range items {
		title, _ := item["title"].(string)
		description, _ := item["description"].(string)
		categoryCounts[classify(title, description)]++
		for _, tag := range extractHashtags(title, description) {
			tagCounts[tag]++
		}
	}
	const maxTags = 120
	tags := sortedCounts(tagCounts)
	if len(tags) > maxTags {
		tags = tags[:maxTags]
	}
	reply(w, 200, map[string]any{
		"categories": sortedCounts(categoryCounts),
		"tags":       tags,
		"total":      len(items),
	})
	return nil
}

func (a *App) libraryList(w http.ResponseWriter, r *http.Request, role string) error {
	q := r.URL.Query()
	offset, _ := strconv.Atoi(q.Get("offset"))
	limit, _ := strconv.Atoi(q.Get("limit"))
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > 200 {
		limit = 60
	}
	tag := strings.TrimSpace(q.Get("tag"))
	category := strings.TrimSpace(q.Get("category"))
	search := strings.ToLower(strings.TrimSpace(q.Get("search")))
	sortBy := q.Get("sort")

	items, err := query(a.DB, `SELECT v.*, IFNULL(s.plays,0) AS plays, IFNULL(s.watched_ms,0) AS watched_ms,
IFNULL(s.completed,0) AS completed_count, s.last_watched_at
FROM videos v LEFT JOIN watch_stats s ON s.video_id=v.id
ORDER BY v.created_at DESC, v.rowid DESC`)
	if err != nil {
		return err
	}
	filtered := make([]map[string]any, 0, len(items))
	for _, item := range items {
		title, _ := item["title"].(string)
		description, _ := item["description"].(string)
		text := strings.ToLower(title + " " + description)
		if search != "" && !strings.Contains(text, search) {
			continue
		}
		if category != "" && classify(title, description) != category {
			continue
		}
		if tag != "" {
			found := false
			for _, t := range extractHashtags(title, description) {
				if t == tag {
					found = true
					break
				}
			}
			if !found {
				continue
			}
		}
		filtered = append(filtered, item)
	}
	plays := func(v map[string]any) int { n, _ := v["plays"].(int64); return int(n) }
	watched := func(v map[string]any) int { n, _ := v["watched_ms"].(int64); return int(n) }
	completed := func(v map[string]any) int { n, _ := v["completed_count"].(int64); return int(n) }
	switch sortBy {
	case "most_played":
		sort.SliceStable(filtered, func(i, j int) bool { return plays(filtered[i]) > plays(filtered[j]) })
	case "most_completed":
		sort.SliceStable(filtered, func(i, j int) bool { return completed(filtered[i]) > completed(filtered[j]) })
	case "most_watched":
		sort.SliceStable(filtered, func(i, j int) bool { return watched(filtered[i]) > watched(filtered[j]) })
	}
	total := len(filtered)
	if offset > total {
		offset = total
	}
	end := offset + limit
	if end > total {
		end = total
	}
	page := filtered[offset:end]
	for _, v := range page {
		if name, _ := v["path"].(string); name != "" && filepath.Base(name) == name {
			if info, e := os.Stat(filepath.Join(a.Config.Data, "videos", name)); e == nil && !info.IsDir() {
				v["size_bytes"] = info.Size()
			}
		}
		a.present(v, role)
	}
	reply(w, 200, map[string]any{"items": page, "total": total, "offset": offset, "limit": limit})
	return nil
}
