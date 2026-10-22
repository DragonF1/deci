// DeciTests/Music/YTMusicRelatedTestSupport.swift
// A real YouTube Music answer pair for the Related songs tests, trimmed: the watch-next tabs of one song (its Related
// tab holds the browse id) and the browse answer for that id (a song shelf, a playlist shelf and a second song shelf).
// Captured once, read only and signed out, from music.youtube.com. Cut down to what Deci reads: tracking params are
// gone, the Up next and Comments panels are cut to their titles, the row menus are cut, a play overlay keeps only its
// target, the cover sizes stay, and each shelf is cut to a few items. Titles, ids and artists are the real ones.

import Foundation
@testable import Deci

nonisolated enum YTRelatedSamples {
    /// The song the watch-next answer was captured for. It is not in any shelf below, as in the real answer.
    static let seedVideoId = "dQw4w9WgXcQ"
    /// The id of the Related tab in `next`.
    static let relatedBrowseId = "MPTRt_6AEOVn4k62q"
    /// The id of the Lyrics tab in `next`, which the Related lookup must not take.
    static let lyricsBrowseId = "MPLYt_6AEOVn4k62q"
    /// The first shelf's title in the real answer.
    static let songShelfTitle = "You might also like"
    /// The video ids of the first shelf's three songs, in order.
    static let songShelfVideoIds = ["QAo_Ycocl1E", "U4zA0xnBEJU", "-SaUrDhp034"]
    /// The video ids of the third shelf's two songs, in order.
    static let otherShelfVideoIds = ["3BFTio5296w", "mtlvMzWnov0"]

    // MARK: - Answers

    /// The watch-next answer: four tabs (Up next, Lyrics, Comments, Related).
    static var next: Data { Data(nextJSON.utf8) }

    /// The same answer with the Related tab taken out.
    static var nextWithoutRelatedTab: Data { editTabs { $0.removeAll { title(of: $0) == "Related" } } }

    /// The same answer with the Related tab greyed out (`unselectable`), as YouTube does for a song with no related
    /// page.
    static var nextWithUnselectableRelatedTab: Data {
        editTabs { tabs in
            for index in tabs.indices where title(of: tabs[index]) == "Related" {
                var renderer = tabs[index]["tabRenderer"] as? [String: Any] ?? [:]
                renderer["unselectable"] = true
                tabs[index]["tabRenderer"] = renderer
            }
        }
    }

    /// The browse answer: shelf 0 is the songs ("You might also like"), shelf 1 the playlists, shelf 2 more songs.
    static var browse: Data { Data(browseJSON.utf8) }

    /// The browse answer with only the shelves at `indexes`, in that order (0 songs, 1 playlists, 2 more songs).
    static func browse(shelves indexes: [Int]) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: browse) as? [String: Any],
              var list = (root["contents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any],
              let all = list["contents"] as? [[String: Any]]
        else { return Data() }
        list["contents"] = indexes.map { all[$0] }
        return (try? JSONSerialization.data(withJSONObject: ["contents": ["sectionListRenderer": list]])) ?? Data()
    }

    private static func title(of tab: [String: Any]) -> String? {
        (tab["tabRenderer"] as? [String: Any])?["title"] as? String
    }

    private static func editTabs(_ change: (inout [[String: Any]]) -> Void) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: next) as? [String: Any] else { return Data() }
        var json = root
        var contents = json["contents"] as? [String: Any] ?? [:]
        var single = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any] ?? [:]
        var tabbed = single["tabbedRenderer"] as? [String: Any] ?? [:]
        var watch = tabbed["watchNextTabbedResultsRenderer"] as? [String: Any] ?? [:]
        var tabs = watch["tabs"] as? [[String: Any]] ?? []
        change(&tabs)
        watch["tabs"] = tabs
        tabbed["watchNextTabbedResultsRenderer"] = watch
        single["tabbedRenderer"] = tabbed
        contents["singleColumnMusicWatchNextResultsRenderer"] = single
        json["contents"] = contents
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    // MARK: - The trimmed JSON


    /// `/next` for the seed song.
    static let nextJSON = #"""
{
  "contents": {
    "singleColumnMusicWatchNextResultsRenderer": {
      "tabbedRenderer": {
        "watchNextTabbedResultsRenderer": {
          "tabs": [
            {"tabRenderer":{"title":"Up next"}},
            {
              "tabRenderer": {
                "endpoint": {
                  "browseEndpoint": {
                    "browseId": "MPLYt_6AEOVn4k62q",
                    "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_TRACK_LYRICS"}}
                  }
                },
                "title": "Lyrics"
              }
            },
            {"tabRenderer":{"title":"Comments"}},
            {
              "tabRenderer": {
                "endpoint": {
                  "browseEndpoint": {
                    "browseId": "MPTRt_6AEOVn4k62q",
                    "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_TRACK_RELATED"}}
                  }
                },
                "title": "Related"
              }
            }
          ]
        }
      }
    }
  }
}
"""#

    /// `/browse` for the Related tab's id.
    static let browseJSON = #"""
{
  "contents": {
    "sectionListRenderer": {
      "contents": [
        {
          "musicCarouselShelfRenderer": {
            "header": {
              "musicCarouselShelfBasicHeaderRenderer": {"title":{"runs":[{"text":"You might also like"}]},"headerStyle":"MUSIC_CAROUSEL_SHELF_BASIC_HEADER_STYLE_DISPLAY_TWO"}
            },
            "contents": [
              {
                "musicResponsiveListItemRenderer": {
                  "thumbnail": {
                    "musicThumbnailRenderer": {
                      "thumbnail": {
                        "thumbnails": [
                          {
                            "url": "https://yt3.googleusercontent.com/VPsyelQLcIhSo_NCqDkcFAnwkDdxPWAvwrrXsureRJH5HJjr5ZapIildtXEObJJYcf-UeUfjXqiOCKVd=w60-h60-l90-rj",
                            "width": 60,
                            "height": 60
                          },
                          {
                            "url": "https://yt3.googleusercontent.com/VPsyelQLcIhSo_NCqDkcFAnwkDdxPWAvwrrXsureRJH5HJjr5ZapIildtXEObJJYcf-UeUfjXqiOCKVd=w120-h120-l90-rj",
                            "width": 120,
                            "height": 120
                          }
                        ]
                      }
                    }
                  },
                  "overlay": {
                    "musicItemThumbnailOverlayRenderer": {
                      "content": {
                        "musicPlayButtonRenderer": {
                          "playNavigationEndpoint": {
                            "watchEndpoint": {"videoId":"QAo_Ycocl1E","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                          }
                        }
                      }
                    }
                  },
                  "flexColumns": [
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Africa",
                              "navigationEndpoint": {
                                "watchEndpoint": {"videoId":"QAo_Ycocl1E","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Toto",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "UCewH1MBbYlEZMWx3ZUNywyg",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Toto IV",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "MPREb_dL9I6V1S1Ta",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  ],
                  "playlistItemData": {"videoId":"QAo_Ycocl1E"},
                  "flexColumnDisplayStyle": "MUSIC_RESPONSIVE_LIST_ITEM_FLEX_COLUMN_DISPLAY_STYLE_TWO_LINE_STACK",
                  "itemHeight": "MUSIC_RESPONSIVE_LIST_ITEM_HEIGHT_MEDIUM_COMPACT"
                }
              },
              {
                "musicResponsiveListItemRenderer": {
                  "thumbnail": {
                    "musicThumbnailRenderer": {
                      "thumbnail": {
                        "thumbnails": [
                          {
                            "url": "https://yt3.googleusercontent.com/MtgMpFQr1pm0uhUaU0cAX-84xEOyzMKaP_q6dskGMejcAHqiphJYAHcw7n_mPtyJkxlLhBdn8V0Xj5sp2A=w60-h60-l90-rj",
                            "width": 60,
                            "height": 60
                          },
                          {
                            "url": "https://yt3.googleusercontent.com/MtgMpFQr1pm0uhUaU0cAX-84xEOyzMKaP_q6dskGMejcAHqiphJYAHcw7n_mPtyJkxlLhBdn8V0Xj5sp2A=w120-h120-l90-rj",
                            "width": 120,
                            "height": 120
                          }
                        ]
                      }
                    }
                  },
                  "overlay": {
                    "musicItemThumbnailOverlayRenderer": {
                      "content": {
                        "musicPlayButtonRenderer": {
                          "playNavigationEndpoint": {
                            "watchEndpoint": {"videoId":"U4zA0xnBEJU","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                          }
                        }
                      }
                    }
                  },
                  "flexColumns": [
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Everybody Wants To Rule The World",
                              "navigationEndpoint": {
                                "watchEndpoint": {"videoId":"U4zA0xnBEJU","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Tears For Fears",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "UCcozhiTOkGB1HCOgdBlEFPA",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Songs From The Big Chair",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "MPREb_FddgzCgpNMC",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  ],
                  "playlistItemData": {"videoId":"U4zA0xnBEJU"},
                  "flexColumnDisplayStyle": "MUSIC_RESPONSIVE_LIST_ITEM_FLEX_COLUMN_DISPLAY_STYLE_TWO_LINE_STACK",
                  "itemHeight": "MUSIC_RESPONSIVE_LIST_ITEM_HEIGHT_MEDIUM_COMPACT"
                }
              },
              {
                "musicResponsiveListItemRenderer": {
                  "thumbnail": {
                    "musicThumbnailRenderer": {
                      "thumbnail": {
                        "thumbnails": [
                          {
                            "url": "https://yt3.googleusercontent.com/Evml9zWq0msFXoyxZlyF6OLs7Wc9jliiAsSZi8ObmP5i0FJyiTr2-GI-rQDaAD6vDsEaK-28vJJPMQA=w60-h60-l90-rj",
                            "width": 60,
                            "height": 60
                          },
                          {
                            "url": "https://yt3.googleusercontent.com/Evml9zWq0msFXoyxZlyF6OLs7Wc9jliiAsSZi8ObmP5i0FJyiTr2-GI-rQDaAD6vDsEaK-28vJJPMQA=w120-h120-l90-rj",
                            "width": 120,
                            "height": 120
                          }
                        ]
                      }
                    }
                  },
                  "overlay": {
                    "musicItemThumbnailOverlayRenderer": {
                      "content": {
                        "musicPlayButtonRenderer": {
                          "playNavigationEndpoint": {
                            "watchEndpoint": {"videoId":"-SaUrDhp034","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                          }
                        }
                      }
                    }
                  },
                  "flexColumns": [
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Every Breath You Take",
                              "navigationEndpoint": {
                                "watchEndpoint": {"videoId":"-SaUrDhp034","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "The Police",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "UCbsRGw640UF_F7AIwHW-zmg",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Synchronicity (Remastered 2003)",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "MPREb_8lrA5KA4Gfv",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  ],
                  "playlistItemData": {"videoId":"-SaUrDhp034"},
                  "flexColumnDisplayStyle": "MUSIC_RESPONSIVE_LIST_ITEM_FLEX_COLUMN_DISPLAY_STYLE_TWO_LINE_STACK",
                  "itemHeight": "MUSIC_RESPONSIVE_LIST_ITEM_HEIGHT_MEDIUM_COMPACT"
                }
              }
            ]
          }
        },
        {
          "musicCarouselShelfRenderer": {
            "header": {
              "musicCarouselShelfBasicHeaderRenderer": {"title":{"runs":[{"text":"Recommended playlists"}]},"headerStyle":"MUSIC_CAROUSEL_SHELF_BASIC_HEADER_STYLE_DISPLAY_TWO"}
            },
            "contents": [
              {
                "musicTwoRowItemRenderer": {
                  "thumbnailRenderer": {
                    "musicThumbnailRenderer": {
                      "thumbnail": {
                        "thumbnails": [
                          {
                            "url": "https://yt3.googleusercontent.com/QU3UwK4rYc0v2G_JoP0H2wXMj_YJ_VLxjhwcZ-io63YXQWkdDWlcfWrwGBYYcO7wUpAputmFWvw=s192",
                            "width": 192,
                            "height": 192
                          },
                          {
                            "url": "https://yt3.googleusercontent.com/QU3UwK4rYc0v2G_JoP0H2wXMj_YJ_VLxjhwcZ-io63YXQWkdDWlcfWrwGBYYcO7wUpAputmFWvw=s576",
                            "width": 576,
                            "height": 576
                          }
                        ]
                      }
                    }
                  },
                  "title": {
                    "runs": [
                      {
                        "text": "pre show\u00e7",
                        "navigationEndpoint": {
                          "browseEndpoint": {
                            "browseId": "VLPLo2bPWKL6TMBefEg9cAq6Fc89HgS-2Ggr",
                            "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}
                          }
                        }
                      }
                    ]
                  },
                  "subtitle": {
                    "runs": [
                      {"text":"Playlist"},
                      {"text":" \u2022 "},
                      {
                        "text": "Romantic technicos",
                        "navigationEndpoint": {
                          "browseEndpoint": {
                            "browseId": "UCqsUfvNYjlwnwzY-pO9OtRg",
                            "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_USER_CHANNEL"}}
                          }
                        }
                      },
                      {"text":" \u2022 "},
                      {"text":"825 views"}
                    ]
                  },
                  "navigationEndpoint": {
                    "browseEndpoint": {
                      "browseId": "VLPLo2bPWKL6TMBefEg9cAq6Fc89HgS-2Ggr",
                      "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}
                    }
                  },
                  "thumbnailCornerOverlay": {
                    "musicThumbnailRenderer": {
                      "thumbnail": {
                        "thumbnails": [
                          {
                            "url": "https://yt3.ggpht.com/ytc/AIdro_nG4SbiRinF1vfW-o9Rnw5llJVk7TkcI6fsy_QOXjoibee1KSsh76gul9To0U7W2NWuBQ=s48-c-k-c0x00000000-no-cc-rj-rp",
                            "width": 48,
                            "height": 48
                          },
                          {
                            "url": "https://yt3.ggpht.com/ytc/AIdro_nG4SbiRinF1vfW-o9Rnw5llJVk7TkcI6fsy_QOXjoibee1KSsh76gul9To0U7W2NWuBQ=s96-c-k-c0x00000000-no-cc-rj-rp",
                            "width": 96,
                            "height": 96
                          },
                          {
                            "url": "https://yt3.ggpht.com/ytc/AIdro_nG4SbiRinF1vfW-o9Rnw5llJVk7TkcI6fsy_QOXjoibee1KSsh76gul9To0U7W2NWuBQ=s48-c-k-c0x00000000-no-cc-rj-rp",
                            "width": 48,
                            "height": 48
                          },
                          {
                            "url": "https://yt3.ggpht.com/ytc/AIdro_nG4SbiRinF1vfW-o9Rnw5llJVk7TkcI6fsy_QOXjoibee1KSsh76gul9To0U7W2NWuBQ=s96-c-k-c0x00000000-no-cc-rj-rp",
                            "width": 96,
                            "height": 96
                          }
                        ]
                      },
                      "onTap": {
                        "browseEndpoint": {
                          "browseId": "UCqsUfvNYjlwnwzY-pO9OtRg",
                          "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_USER_CHANNEL"}}
                        }
                      }
                    }
                  }
                }
              },
              {
                "musicTwoRowItemRenderer": {
                  "thumbnailRenderer": {
                    "musicThumbnailRenderer": {
                      "thumbnail": {
                        "thumbnails": [
                          {
                            "url": "https://yt3.googleusercontent.com/-tjg2qJc4FcGfgqxVKNR8NdQikIFX6xBf5gYRtb-VwbWRcLpwILvwMU5whYTwyWMMKxpzWhztceb2Q=w226-h226-l90-rj",
                            "width": 226,
                            "height": 226
                          },
                          {
                            "url": "https://yt3.googleusercontent.com/-tjg2qJc4FcGfgqxVKNR8NdQikIFX6xBf5gYRtb-VwbWRcLpwILvwMU5whYTwyWMMKxpzWhztceb2Q=w544-h544-l90-rj",
                            "width": 544,
                            "height": 544
                          }
                        ]
                      }
                    }
                  },
                  "title": {
                    "runs": [
                      {
                        "text": "'80s Rock",
                        "navigationEndpoint": {
                          "browseEndpoint": {
                            "browseId": "VLRDCLAK5uy_lvHI2Z7dSfpD5g8wvmePjWPfYwq5IgkLo",
                            "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}
                          }
                        }
                      }
                    ]
                  },
                  "subtitle": {"runs":[{"text":"Playlist"},{"text":" \u2022 "},{"text":"YouTube Music"}]},
                  "navigationEndpoint": {
                    "browseEndpoint": {
                      "browseId": "VLRDCLAK5uy_lvHI2Z7dSfpD5g8wvmePjWPfYwq5IgkLo",
                      "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}
                    }
                  }
                }
              }
            ]
          }
        },
        {
          "musicCarouselShelfRenderer": {
            "header": {
              "musicCarouselShelfBasicHeaderRenderer": {"title":{"runs":[{"text":"Other performances"}]},"headerStyle":"MUSIC_CAROUSEL_SHELF_BASIC_HEADER_STYLE_DISPLAY_TWO"}
            },
            "contents": [
              {
                "musicResponsiveListItemRenderer": {
                  "thumbnail": {
                    "musicThumbnailRenderer": {
                      "thumbnail": {
                        "thumbnails": [
                          {
                            "url": "https://yt3.googleusercontent.com/SCoMmJu-MRsB4-81EKNgLE-sv9LgLsP6q8aj8TFRE9I8GDPJww-UPzZr-k6C_mCg9q2-V4GzbNtU32pX=w60-h60-l90-rj",
                            "width": 60,
                            "height": 60
                          },
                          {
                            "url": "https://yt3.googleusercontent.com/SCoMmJu-MRsB4-81EKNgLE-sv9LgLsP6q8aj8TFRE9I8GDPJww-UPzZr-k6C_mCg9q2-V4GzbNtU32pX=w120-h120-l90-rj",
                            "width": 120,
                            "height": 120
                          }
                        ]
                      }
                    }
                  },
                  "overlay": {
                    "musicItemThumbnailOverlayRenderer": {
                      "content": {
                        "musicPlayButtonRenderer": {
                          "playNavigationEndpoint": {
                            "watchEndpoint": {"videoId":"3BFTio5296w","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                          }
                        }
                      }
                    }
                  },
                  "flexColumns": [
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Never Gonna Give You Up (2022 Remaster)",
                              "navigationEndpoint": {
                                "watchEndpoint": {"videoId":"3BFTio5296w","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Rick Astley",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "UCwZEU0wAwIyZb4x5G_KJp2w",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Whenever You Need Somebody (Deluxe Edition - 2022 Remaster)",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "MPREb_0ihgukxWfht",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  ],
                  "playlistItemData": {"videoId":"3BFTio5296w"},
                  "flexColumnDisplayStyle": "MUSIC_RESPONSIVE_LIST_ITEM_FLEX_COLUMN_DISPLAY_STYLE_TWO_LINE_STACK",
                  "itemHeight": "MUSIC_RESPONSIVE_LIST_ITEM_HEIGHT_MEDIUM_COMPACT"
                }
              },
              {
                "musicResponsiveListItemRenderer": {
                  "thumbnail": {
                    "musicThumbnailRenderer": {
                      "thumbnail": {
                        "thumbnails": [
                          {
                            "url": "https://yt3.googleusercontent.com/H5NoR9DAplSlbYzZAypa6ffchmocJoAS9Tqt41AaEJjeoaH73MBbiryeSk4sMNsRBLb04Sn22SRe6BcS=w60-h60-l90-rj",
                            "width": 60,
                            "height": 60
                          },
                          {
                            "url": "https://yt3.googleusercontent.com/H5NoR9DAplSlbYzZAypa6ffchmocJoAS9Tqt41AaEJjeoaH73MBbiryeSk4sMNsRBLb04Sn22SRe6BcS=w120-h120-l90-rj",
                            "width": 120,
                            "height": 120
                          }
                        ]
                      }
                    }
                  },
                  "overlay": {
                    "musicItemThumbnailOverlayRenderer": {
                      "content": {
                        "musicPlayButtonRenderer": {
                          "playNavigationEndpoint": {
                            "watchEndpoint": {"videoId":"mtlvMzWnov0","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                          }
                        }
                      }
                    }
                  },
                  "flexColumns": [
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Never Gonna Give You Up",
                              "navigationEndpoint": {
                                "watchEndpoint": {"videoId":"mtlvMzWnov0","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "OxYy",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "UCr5ue0A7JY0S8r6hAqKfjJA",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    },
                    {
                      "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                          "runs": [
                            {
                              "text": "Never Gonna Give You Up",
                              "navigationEndpoint": {
                                "browseEndpoint": {
                                  "browseId": "MPREb_6LzcG8wF8Gq",
                                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  ],
                  "playlistItemData": {"videoId":"mtlvMzWnov0"},
                  "flexColumnDisplayStyle": "MUSIC_RESPONSIVE_LIST_ITEM_FLEX_COLUMN_DISPLAY_STYLE_TWO_LINE_STACK",
                  "itemHeight": "MUSIC_RESPONSIVE_LIST_ITEM_HEIGHT_MEDIUM_COMPACT"
                }
              }
            ]
          }
        }
      ]
    }
  }
}
"""#

}
