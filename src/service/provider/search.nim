# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License
#          Made by Humans from OpenPeeps

## This module implements the Spotlight search provider service for StupidGreen.
##
## It defines a Spotlight service that maintains a search index of blog posts,
## allowing for efficient search and retrieval of content based on URLs, titles,
## descriptions, and headings.

import std/[strutils, tables]
import pkg/supranim/core/[services]

initService Spotlight[Singleton]:
  backend do:
    type
      Entry* = object
        url*: string
          ## URL of the entry
        title*: string
          ## Title of the entry
        description*: Option[string]
          ## Short description of the entry
        headings*: Option[seq[string]]
          ## Optional list of headings within the entry
          ## to improve search granularity

      Spotlight* = object
        entries: seq[Entry]
          ## Sequence of search entries
        index*: TableRef[string, int]
          ## A table for indexing entries

      SpotlightInstance* = ptr Spotlight

  client do:
    proc init*() =
      ## Initialize the Spotlight singleton service
      let spotlight = getSpotlightInstance(
        proc(instance: SpotlightInstance) =
          instance.index = newTable[string, int]()
      )

    proc spotlight*(): SpotlightInstance {.inline.} =
      ## Retrieve the Spotlight singleton instance
      getSpotlightInstance()

    proc addEntry*(spotlight: SpotlightInstance, key, url, title: string,
                    description: Option[string] = none(string),
                    headings: Option[seq[string]] = none(seq[string])) =
      ## Add a new entry to the Spotlight search index
      if spotlight.index.contains(key):
        return # entry already exists
      spotlight.index[key] = spotlight.entries.len
      spotlight.entries.add(Entry(url: url, title: title,
              description: description,
              headings: headings))

    proc getEntries*(spotlight: SpotlightInstance): seq[Entry] =
      ## Retrieve all entries in the Spotlight search index
      return spotlight.entries

    proc clear*(spotlight: SpotlightInstance) =
      ## Clears all entries in the Spotlight search index
      spotlight.entries = @[]
      spotlight.index = newTable[string, int]()
