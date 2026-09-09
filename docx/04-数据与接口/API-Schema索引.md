# KA Music 后端 API Schema 索引（自动生成）

> 文档编号：KA-04-04
> 级别：L1 📌
> 状态：现行
> 关联代码：项目根目录 api.json（脚本自动生成）
> 最近更新：2026-09-08
> 变更触发条件：api.json 更新后重新生成

> 共 **111** 个 schema，来源 `components.schemas`。

| # | Schema | 类型 | 属性数 | 属性名 |
|---|---|---|---|---|
| 1 | `AddSongItem` | object | 3 | `hash`, `fileid`, `name` |
| 2 | `AddSongResponse` | object | 5 | `count`, `listid`, `info`, `status`, `error_code` |
| 3 | `AddTracksRequest` | object | 2 | `listId`, `songs` |
| 4 | `AlbumLite` | object | 4 | `id`, `name`, `status`, `error_code` |
| 5 | `AlbumSongAlbumInfo` | object | 2 | `album_name`, `cover` |
| 6 | `AlbumSongAudioInfo` | object | 2 | `hash`, `duration` |
| 7 | `AlbumSongAuthor` | object | 2 | `author_id`, `author_name` |
| 8 | `AlbumSongBase` | object | 3 | `audio_name`, `author_name`, `album_id` |
| 9 | `AlbumSongItem` | object | 6 | `base`, `audio_info`, `album_info`, `authors`, `status`, `error_code` |
| 10 | `AppVersionDto` | object | 7 | `platform`, `versionName`, `versionCode`, `updateContent`, `downloadUrl`, `forceUpdate`, `releaseDate` |
| 11 | `ArtistAlbumAuthor` | object | 2 | `author_name`, `author_id` |
| 12 | `ArtistAlbumExtra` | object | 1 | `page_total` |
| 13 | `ArtistAlbumItem` | object | 11 | `album_id`, `album_name`, `author_name`, `cover`, `sizable_cover`, `authors`, `publish_date`, `intro`, `type`, `status`, `error_code` |
| 14 | `ArtistAlbumResponse` | object | 5 | `total`, `data`, `extra`, `status`, `error_code` |
| 15 | `ArtistVideoExtra` | object | 1 | `page_total` |
| 16 | `ArtistVideoItem` | object | 17 | `video_id`, `video_name`, `author_name`, `cover`, `hdpic`, `publish_date`, `timelength`, `audio_hash`, `album_audio_id`, `history_heat`, `heat`, `topic`, `remark`, `intro`, `type`, `is_short`, `h264` |
| 17 | `ArtistVideoResponse` | object | 5 | `total`, `extra`, `data`, `status`, `error_code` |
| 18 | `AudioImageAuthor` | object | 8 | `author_id`, `author_name`, `is_publish`, `res_hash`, `avatar`, `sizable_avatar`, `audio_publish_date`, `imgs` |
| 19 | `AudioImageItem` | object | 6 | `id`, `file_hash`, `sizable_portrait`, `filename`, `publish_time`, `source` |
| 20 | `AudioImageResponse` | object | 5 | `errcode`, `errmsg`, `data`, `status`, `error_code` |
| 21 | `AudioMatchAlbum` | object | 5 | `albumid`, `albumname`, `publish_date`, `img`, `scid` |
| 22 | `AudioMatchAuthor` | object | 2 | `author_id`, `author_name` |
| 23 | `AudioMatchItem` | object | 28 | `songid`, `mixsongid`, `audio_id`, `album_id`, `scid`, `similar_scid`, `songname`, `songNameSuffix`, `singername`, `remark`, `str_song_type`, `source`, `union_cover`, `hash_128`, `hash_320`, `hash_flac`, `dist`, `dist_nomelody`, `timeoffset`, `timelength_128`, `timelength_320`, `timelength_flac`, `privilege`, `is_play_free`, `is_original` … |
| 24 | `AudioMatchResponse` | object | 6 | `server_time`, `pcm_second`, `process`, `data`, `status`, `error_code` |
| 25 | `AudioMvItem` | object | 31 | `is_recommend`, `user_id`, `hot`, `hit`, `user_name`, `songid`, `thumb`, `desc`, `__status`, `singer`, `other_desc`, `hdpic`, `is_ugc`, `have_mp4`, `audio_id`, `album_audio_id`, `is_publish`, `download_total`, `collection_total`, `is_short`, `remark`, `video_id`, `user_avatar`, `music_trac`, `mv_name` … |
| 26 | `AudioMvResponse` | object | 3 | `data`, `status`, `error_code` |
| 27 | `BusiVipInfo` | object | 6 | `is_vip`, `product_type`, `busi_type`, `vip_begin_time`, `vip_end_time`, `vip_clearday` |
| 28 | `CommentClassifyItem` | object | 4 | `id`, `label`, `icon`, `cnt` |
| 29 | `CommentConfig` | object | 2 | `emptyTip`, `input_hint` |
| 30 | `CommentHotWord` | object | 2 | `content`, `count` |
| 31 | `CommentImage` | object | 3 | `url`, `width`, `height` |
| 32 | `CommentLikeInfo` | object | 3 | `count`, `haslike`, `likenum` |
| 33 | `CommentSongScore` | object | 2 | `score_user_count`, `song_score` |
| 34 | `CommentTag` | object | 3 | `name`, `type`, `count` |
| 35 | `CommentTailInfo` | object | 2 | `id`, `name` |
| 36 | `CommentUserDetail` | object | 5 | `medal_type`, `medal_roll_word`, `word_v3`, `pendant_name`, `pendant_url` |
| 37 | `CommentVipInfo` | object | 3 | `vip_type`, `m_type`, `user_type` |
| 38 | `DailyRecommendResponse` | object | 6 | `creation_date`, `cover_img_url`, `sub_title`, `song_list`, `status`, `error_code` |
| 39 | `DailyRecommendSong` | object | 21 | `songname`, `author_name`, `hash`, `time_length`, `album_id`, `album_name`, `songid`, `mixsongid`, `sizable_cover`, `rec_copy_write`, `rec_sub_copy_write`, `hash_320`, `filesize_320`, `hash_flac`, `filesize_flac`, `hash_192`, `privilege`, `is_original`, `singerinfo`, `status`, `error_code` |
| 40 | `ExternalPlaylistParseRequest` | object | 1 | `sourceText` |
| 41 | `ExternalPlaylistParseResponse` | object | 3 | `sourcePlatform`, `playlistName`, `songNames` |
| 42 | `FmImageData` | object | 5 | `fmid`, `fmtype`, `imgUrl50`, `imgUrl100`, `imgUrl100_size` |
| 43 | `FmImageResponse` | object | 3 | `data`, `status`, `error_code` |
| 44 | `FmRecommendCategory` | object | 8 | `fmid`, `fmname`, `classid`, `classname`, `description`, `banner`, `imgurl`, `rcmdlist` |
| 45 | `FmRecommendResponse` | object | 3 | `data`, `status`, `error_code` |
| 46 | `FmRecommendSong` | object | 8 | `name`, `hash`, `audio_id`, `album_audio_id`, `album_id`, `time`, `privilege`, `trans_param` |
| 47 | `FmSongData` | object | 5 | `fmid`, `fmtype`, `offset`, `size`, `songs` |
| 48 | `FmSongItem` | object | 21 | `name`, `hash`, `320hash`, `hashflac`, `hash_high`, `audio_id`, `album_id`, `album_audio_id`, `time`, `320time`, `size`, `320size`, `filesize_flac`, `privilege`, `vip`, `ext`, `trans_param`, `tracker_info`, `all_privs`, `status`, `error_code` |
| 49 | `FmSongResponse` | object | 3 | `data`, `status`, `error_code` |
| 50 | `FmTrackerInfo` | object | 3 | `auth`, `module_id`, `open_time` |
| 51 | `FmTransParam` | object | 4 | `union_cover`, `language`, `is_original`, `cid` |
| 52 | `IFormFile` | string | 0 |  |
| 53 | `JsonElement` | - | 0 |  |
| 54 | `LyricResult` | object | 4 | `rawContent`, `decodedContent`, `decodedTranslation`, `rawJson` |
| 55 | `MobileLoginAccountDto` | object | 5 | `userId`, `nickname`, `pic`, `appId`, `username` |
| 56 | `MobileLoginAccountSelectionResponse` | object | 5 | `status`, `errorCode`, `requiresUserSelection`, `message`, `accounts` |
| 57 | `MobileLoginRequest` | object | 3 | `mobile`, `code`, `userId` |
| 60 | `OneDayVipModel` | object | 4 | `ad_vip_num`, `ad_vip_end_time`, `status`, `error_code` |
| 61 | `PersonalFmResponse` | object | 4 | `song_list`, `mode`, `status`, `error_code` |
| 62 | `PersonalFmSong` | object | 12 | `songname`, `author_name`, `hash`, `time_length`, `album_id`, `songid`, `mixsongid`, `privilege`, `singerinfo`, `trans_param`, `status`, `error_code` |
| 63 | `PlaylistInfo` | object | 12 | `listid`, `global_collection_id`, `name`, `pic`, `intro`, `count`, `list_create_username`, `list_create_userid`, `heat`, `create_time`, `status`, `error_code` |
| 64 | `PlaylistSong` | object | 12 | `name`, `hash`, `timelen`, `album_id`, `privilege`, `fileid`, `singerinfo`, `albuminfo`, `cover`, `mixsongid`, `status`, `error_code` |
| 65 | `PlaylistSongResponse` | object | 4 | `count`, `songs`, `status`, `error_code` |
| 66 | `PlaylistTagCategory` | object | 7 | `parent_id`, `sort`, `tag_id`, `tag_name`, `son`, `status`, `error_code` |
| 67 | `PlaylistTagItem` | object | 6 | `parent_id`, `tag_id`, `tag_name`, `sort`, `status`, `error_code` |
| 68 | `PlayUrlData` | object | 6 | `url`, `hash`, `priv_status`, `err_code`, `status`, `error_code` |
| 69 | `PrivilegeAudioInfo` | object | 6 | `duration`, `filesize`, `bitrate`, `extname`, `image`, `imgsize` |
| 70 | `PrivilegeLiteData` | object | 21 | `type`, `id`, `album_id`, `recommend_album_id`, `album_audio_id`, `hash`, `name`, `singername`, `albumname`, `level`, `quality`, `privilege`, `status`, `pay_type`, `price`, `pkg_price`, `info`, `trans_param`, `_msg`, `_errno`, `relate_goods` |
| 71 | `PrivilegeQualityMap` | object | 3 | `attr0`, `attr1`, `bits` |
| 72 | `PrivilegeTransParam` | object | 12 | `cid`, `language`, `is_original`, `hash_multitrack`, `union_cover`, `ogg_128_hash`, `ogg_128_filesize`, `ogg_320_hash`, `ogg_320_filesize`, `classmap`, `qualitymap`, `ipmap` |
| 73 | `ProblemDetails` | object | 5 | `type`, `title`, `status`, `detail`, `instance` |
| 74 | `QRCode` | object | 4 | `qrcode`, `qrcode_img`, `status`, `error_code` |
| 75 | `QrLoginStatusResponse` | object | 6 | `userid`, `nickname`, `pic`, `token`, `status`, `error_code` |
| 76 | `RankAlbum` | object | 4 | `sizable_cover`, `album_name`, `status`, `error_code` |
| 77 | `RankListItem` | object | 3 | `img_9`, `rankid`, `rankname` |
| 78 | `RankListResponse` | object | 3 | `info`, `status`, `error_code` |
| 79 | `RankSongAudioInfo` | object | 2 | `hash`, `duration` |
| 80 | `RankSongAuthor` | object | 2 | `author_id`, `author_name` |
| 81 | `RankSongItem` | object | 8 | `deprecated`, `album_id`, `authors`, `songname`, `trans_param`, `album_info`, `status`, `error_code` |
| 82 | `RankSongResponse` | object | 4 | `total`, `songlist`, `status`, `error_code` |
| 83 | `RecommendPlaylistItem` | object | 12 | `specialid`, `global_collection_id`, `specialname`, `nickname`, `suid`, `play_count`, `collectcount`, `intro`, `flexible_cover`, `tags`, `status`, `error_code` |
| 84 | `RecommendPlaylistResponse` | object | 4 | `has_next`, `special_list`, `status`, `error_code` |
| 85 | `RefreshTokenResponse` | object | 6 | `userid`, `token`, `is_vip`, `t1`, `status`, `error_code` |
| 86 | `RemoveSongResponse` | object | 5 | `count`, `listid`, `last_time`, `status`, `error_code` |
| 87 | `SearchAlbumItem` | object | 9 | `albumid`, `albumname`, `singer`, `songcount`, `publish_time`, `ostremark`, `img`, `status`, `error_code` |
| 88 | `SearchHotCategory` | object | 2 | `name`, `keywords` |
| 89 | `SearchHotKeyword` | object | 7 | `keyword`, `reason`, `jumpurl`, `json_url`, `is_cover_word`, `type`, `icon` |
| 90 | `SearchHotResponse` | object | 2 | `timestamp`, `list` |
| 91 | `SearchPlaylistItem` | object | 10 | `specialname`, `specialid`, `gid`, `song_count`, `nickname`, `total_play_count`, `img`, `publish_time`, `status`, `error_code` |
| 92 | `SendCodeResponse` | object | 3 | `code`, `status`, `error_code` |
| 93 | `SingerAudioResponse` | object | 4 | `total`, `data`, `status`, `error_code` |
| 94 | `SingerDetailResponse` | object | 5 | `birthday`, `author_name`, `sizable_avatar`, `status`, `error_code` |
| 95 | `SingerLite` | object | 5 | `id`, `name`, `avatar`, `status`, `error_code` |
| 96 | `SingerSongItem` | object | 10 | `audio_name`, `hash`, `album_id`, `album_audio_id`, `album_name`, `author_name`, `timelength`, `trans_param`, `status`, `error_code` |
| 97 | `TransParam` | object | 1 | `union_cover` |
| 98 | `UpgradeVipModel` | object | 3 | `recharge_hours`, `status`, `error_code` |
| 99 | `UserCloudAlbumInfo` | object | 8 | `album_id`, `album_name`, `publish_date`, `category`, `is_publish`, `sizable_cover`, `status`, `error_code` |
| 100 | `UserCloudAuthor` | object | 5 | `author_id`, `author_name`, `sizable_avatar`, `status`, `error_code` |
| 101 | `UserCloudResponse` | object | 8 | `list`, `list_count`, `used_size`, `availble_size`, `max_size`, `user_type`, `status`, `error_code` |
| 102 | `UserCloudSong` | object | 17 | `name`, `hash`, `hash_std`, `audio_id`, `album_audio_id`, `kmr_album_audio_id`, `author_name`, `authors`, `timelen`, `size`, `bitrate`, `ext`, `add_time`, `kv_id`, `album_info`, `status`, `error_code` |
| 103 | `UserCloudUrlResponse` | object | 7 | `fileSize`, `url`, `backup_url`, `extName`, `hash`, `status`, `error_code` |
| 104 | `UserDetailModel` | object | 4 | `nickname`, `pic`, `status`, `error_code` |
| 105 | `UserPlaylistItem` | object | 14 | `name`, `listid`, `global_collection_id`, `list_create_gid`, `list_create_listid`, `count`, `pic`, `is_def`, `create_time`, `type`, `musiclib_id`, `list_create_username`, `status`, `error_code` |
| 106 | `UserPlaylistResponse` | object | 5 | `userid`, `list_count`, `info`, `status`, `error_code` |
| 107 | `UserVipResponse` | object | 8 | `userid`, `is_vip`, `vip_type`, `busi_vip`, `isSuperVip`, `isConceptVip`, `status`, `error_code` |
| 108 | `VideoH264Info` | object | 15 | `ld_hash`, `ld_filesize`, `ld_bitrate`, `sd_hash`, `sd_filesize`, `sd_bitrate`, `qhd_hash`, `qhd_filesize`, `qhd_bitrate`, `hd_hash`, `hd_filesize`, `hd_bitrate`, `fhd_hash`, `fhd_filesize`, `fhd_bitrate` |
| 109 | `VipFutureDuration` | object | 4 | `up_seconds`, `duration`, `seconds`, `month_num` |
| 110 | `VipReceiveHistoryResponse` | object | 7 | `month`, `server_time`, `list`, `sign_list`, `future_duration`, `status`, `error_code` |
| 111 | `VipReceiveItem` | object | 3 | `day`, `receive_vip`, `vip_type` |
