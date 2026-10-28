package main

import (
	"encoding/json"
	"familyvideo/server/internal/family"
	"flag"
	"fmt"
	"github.com/gofrs/flock"
	"os"
	"path/filepath"
)

func runCommand(config family.Config, args []string) error {
	command := args[0]
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	input := flags.String("input", "", "backup archive")
	output := flags.String("output", "", "new backup archive")
	data := flags.String("data", "", "new restore directory")
	app := flags.String("app", "", "kids, parent or tv")
	apk := flags.String("apk", "", "APK file")
	aapt := flags.String("aapt", "aapt", "Android SDK aapt executable")
	apply := flags.Bool("apply", false, "move old orphan files to quarantine")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	switch command {
	case "publish-apk":
		if *apk == "" || (*app != "kids" && *app != "parent" && *app != "tv") {
			return fmt.Errorf("用法: publish-apk -app kids|parent|tv -apk FILE -aapt PATH")
		}
		release, err := family.PublishAPK(config, *app, *apk, *aapt)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(release)
	case "verify-backup":
		if *input == "" {
			return fmt.Errorf("请提供 -input 备份文件")
		}
		if err := family.VerifyBackup(*input); err != nil {
			return err
		}
		fmt.Println("备份完整性校验通过")
		return nil
	case "backup", "restore", "orphans":
	default:
		return fmt.Errorf("未知命令，可用: backup / verify-backup / restore / orphans / publish-apk")
	}
	lock := flock.New(filepath.Join(config.Data, "server.lock"))
	ok, err := lock.TryLock()
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("请先停止 HTTP 服务，再进行完整备份、恢复或孤儿文件维护")
	}
	defer lock.Unlock()
	if command == "restore" {
		if *input == "" || *data == "" {
			return fmt.Errorf("用法: restore -input FILE.zip -data NEW_DIRECTORY")
		}
		if err = family.RestoreBackup(*input, *data); err != nil {
			return err
		}
		fmt.Println("恢复并校验成功；将 FAMILY_DATA_DIR 指向新目录后启动服务")
		return nil
	}
	instance, err := family.New(config)
	if err != nil {
		return err
	}
	defer instance.DB.Close()
	if command == "backup" {
		if *output == "" {
			return fmt.Errorf("用法: backup -output NEW_FILE.zip")
		}
		if err = family.CreateBackup(instance, *output); err != nil {
			return err
		}
		fmt.Println("完整备份已创建：", *output)
		return nil
	}
	files, err := family.ScanOrphans(instance, *apply)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(files)
}
