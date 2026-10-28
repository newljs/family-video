package family

import (
	"fmt"
	"testing"
)

func seedLibrary(t *testing.T, a *App, id, title, description string) {
	t.Helper()
	if _, err := a.DB.Exec(
		"INSERT INTO videos(id,title,path,duration,width,height,description) VALUES(?,?,?,60,160,120,?)",
		id, title, id+".mp4", description,
	); err != nil {
		t.Fatal(err)
	}
	tx, err := a.DB.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if err = indexVideo(tx, id, title, description); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func TestLibraryClassifyAndMeta(t *testing.T) {
	if got := classify("趣味英语动画", "#儿童英语 #启蒙英语"); got != "英语启蒙" {
		t.Fatalf("classify = %q, want 英语启蒙", got)
	}
	if got := classify("花生刨了吗", "#一份耕耘一份收获"); got != "未分类" {
		t.Fatalf("classify = %q, want 未分类", got)
	}
	a := testApp(t)
	seedLibrary(t, a, "v1", "趣味英语动画 花蝴蝶", "#儿童英语 #启蒙英语")
	seedLibrary(t, a, "v2", "嘻哈歌曲背近代史", "#历史 #嘻哈")
	seedLibrary(t, a, "v3", "田园生活", "#耕耘")

	meta := object(t, request(t, a, "GET", "/api/library/meta", "parent", nil))
	categories, _ := meta["categories"].([]any)
	byName := map[string]float64{}
	for _, raw := range categories {
		c := raw.(map[string]any)
		byName[c["name"].(string)] = c["count"].(float64)
	}
	if byName["英语启蒙"] != 1 || byName["历史人文"] != 1 || byName["未分类"] != 1 {
		t.Fatalf("category counts wrong: %v", byName)
	}
	if meta["total"] != float64(3) {
		t.Fatalf("total = %v", meta["total"])
	}
}

func TestLibraryListFiltersAndPagination(t *testing.T) {
	a := testApp(t)
	seedLibrary(t, a, "v1", "英语动画一", "#儿童英语 #启蒙英语")
	seedLibrary(t, a, "v2", "英语动画二", "#儿童英语")
	seedLibrary(t, a, "v3", "历史故事", "#历史")
	for i := 0; i < 3; i++ {
		if _, err := a.DB.Exec(
			"INSERT INTO watch_stats(video_id, plays, watched_ms, completed) VALUES(?,?,?,?)",
			fmt.Sprintf("v%d", i+1), i, int64(i)*1000, i%2,
		); err != nil {
			t.Fatal(err)
		}
	}

	// 分页：limit=2 第一页 v3,v2（同秒插入按 rowid 倒序），第二页 v1。
	page1 := object(t, request(t, a, "GET", "/api/library?limit=2", "parent", nil))
	if page1["total"] != float64(3) {
		t.Fatalf("total = %v", page1["total"])
	}
	items := page1["items"].([]any)
	if len(items) != 2 || items[0].(map[string]any)["id"] != "v3" {
		t.Fatalf("page1 wrong: %v", items)
	}
	page2 := object(t, request(t, a, "GET", "/api/library?limit=2&offset=2", "parent", nil))
	items = page2["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["id"] != "v1" {
		t.Fatalf("page2 wrong: %v", items)
	}

	// 话题标签筛选。
	tagged := object(t, request(t, a, "GET", "/api/library?tag=儿童英语", "parent", nil))
	if tagged["total"] != float64(2) {
		t.Fatalf("tag filter total = %v", tagged["total"])
	}
	// 分类筛选。
	byCategory := object(t, request(t, a, "GET", "/api/library?category=%E5%8E%86%E5%8F%B2%E4%BA%BA%E6%96%87", "parent", nil))
	if byCategory["total"] != float64(1) {
		t.Fatalf("category filter total = %v", byCategory["total"])
	}
	// 搜索 + 排序（播放最多 → v3, v2, v1）。
	sorted := object(t, request(t, a, "GET", "/api/library?sort=most_played&limit=1", "parent", nil))
	first := sorted["items"].([]any)[0].(map[string]any)
	if first["id"] != "v3" {
		t.Fatalf("sort most_played first = %v", first["id"])
	}
	// 组合：搜索限定后 total 收窄。
	combined := object(t, request(t, a, "GET", "/api/library?search=%E8%8B%B1%E8%AF%AD&tag=%E5%84%BF%E7%AB%A5%E8%8B%B1%E8%AF%AD", "parent", nil))
	if combined["total"] != float64(2) {
		t.Fatalf("combined filter total = %v", combined["total"])
	}
	// 非法 limit 收敛到默认，不报错。
	if w := request(t, a, "GET", "/api/library?limit=9999", "parent", nil); w.Code != 200 {
		t.Fatalf("bad limit should clamp, got %d", w.Code)
	}
}
