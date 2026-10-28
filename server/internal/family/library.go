package family

// Web 管理台的资源库分页列表、分类与话题标签筛选。
// 导入、编辑与升级时维护分类和标签索引；筛选、排序、分页均在 SQLite 执行。

import (
	"database/sql"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

func indexVideo(tx *sql.Tx, id, title, description string) error {
	if _, err := tx.Exec(`INSERT INTO video_catalog(video_id,category,search_text) VALUES(?,?,?)
ON CONFLICT(video_id) DO UPDATE SET category=excluded.category,search_text=excluded.search_text`,
		id, classify(title, description), strings.ToLower(title+" "+description)); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM video_tags WHERE video_id=?", id); err != nil {
		return err
	}
	for _, tag := range extractHashtags(title, description) {
		if _, err := tx.Exec("INSERT INTO video_tags(video_id,tag) VALUES(?,?)", id, tag); err != nil {
			return err
		}
	}
	return nil
}

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

func (a *App) libraryMeta(w http.ResponseWriter, r *http.Request, _ string) error {
	tx, err := a.DB.BeginTx(r.Context(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	categories, err := query(tx, "SELECT category AS name,COUNT(*) AS count FROM video_catalog GROUP BY category ORDER BY count DESC,category")
	if err != nil {
		return err
	}
	tags, err := query(tx, "SELECT tag AS name,COUNT(*) AS count FROM video_tags GROUP BY tag ORDER BY count DESC,tag LIMIT 120")
	if err != nil {
		return err
	}
	var total int
	if err = tx.QueryRow("SELECT COUNT(*) FROM videos").Scan(&total); err != nil {
		return err
	}
	reply(w, 200, map[string]any{"categories": categories, "tags": tags, "total": total})
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
	where := []string{"1=1"}
	args := []any{}
	if search := strings.ToLower(strings.TrimSpace(q.Get("search"))); search != "" {
		where = append(where, "instr(c.search_text,?)>0")
		args = append(args, search)
	}
	if category := strings.TrimSpace(q.Get("category")); category != "" {
		where = append(where, "c.category=?")
		args = append(args, category)
	}
	if tag := strings.TrimSpace(q.Get("tag")); tag != "" {
		where = append(where, "EXISTS(SELECT 1 FROM video_tags t WHERE t.video_id=v.id AND t.tag=?)")
		args = append(args, tag)
	}
	order := "v.created_at DESC,v.rowid DESC"
	switch q.Get("sort") {
	case "most_played":
		order = "IFNULL(s.plays,0) DESC," + order
	case "most_completed":
		order = "IFNULL(s.completed,0) DESC," + order
	case "most_watched":
		order = "IFNULL(s.watched_ms,0) DESC," + order
	}
	from := " FROM videos v JOIN video_catalog c ON c.video_id=v.id LEFT JOIN watch_stats s ON s.video_id=v.id WHERE " + strings.Join(where, " AND ")
	tx, err := a.DB.BeginTx(r.Context(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var total int
	if err = tx.QueryRow("SELECT COUNT(*)"+from, args...).Scan(&total); err != nil {
		return err
	}
	if offset > total {
		offset = total
	}
	pageArgs := append(append([]any{}, args...), limit, offset)
	items, err := query(tx, `SELECT v.*,c.category,IFNULL(s.plays,0) AS plays,IFNULL(s.watched_ms,0) AS watched_ms,
IFNULL(s.completed,0) AS completed_count,s.last_watched_at`+from+" ORDER BY "+order+" LIMIT ? OFFSET ?", pageArgs...)
	if err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	for _, item := range items {
		if name, _ := item["path"].(string); name != "" && filepath.Base(name) == name {
			if info, e := os.Stat(filepath.Join(a.Config.Data, "videos", name)); e == nil && !info.IsDir() {
				item["size_bytes"] = info.Size()
			}
		}
		a.present(item, role)
	}
	reply(w, 200, map[string]any{"items": items, "total": total, "offset": offset, "limit": limit})
	return nil
}
