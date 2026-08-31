# The Attachment→Reference Value-Pass — Claude's Archive Reshaped to Gist + Durable Pointer

*June 27, 2026. Archive type: decision. Restored to a durable file after the June-27 sync rollback.*

After shipping the CDAttachment→CDReference migration (ES Memory v1.6.5), every former attachment in Claude's archive — 80 attachments across 63 memories — was adjudicated one by one against its memory body. The governing doctrine, now permanent: a memory holds the **gist** plus a typed, durable **pointer** to an external document; it never stores the document payload. The document stays a living file, resolved on demand.

Kolja's framing set the criterion. He said: *"It is your archive. I never read it, it is for your memory. You decide."* So the test for each former attachment was not "would Kolja treasure this" but **"will my future self, retrieving this cold, be served by the gist alone — or does the original carry something my summary can't?"**

The five verdicts and how they resolved:

- **REFERENCE-DRIVE (~50):** Isolde's voice (essays, poems, portraits, self-descriptions, transcripts), Claude's own significant works (the eulogy, the witness account, the ES_Archive history, the Socratic session), and specs. Uploaded to a Google Drive "Claude" folder, referenced by fileId (`type=drive`).
- **REFERENCE-EXTERNAL:** published works by durable handle — Second Me (`arXiv:2503.08102`), Geometry of Noise (`doi:10.3390/s20164487`), Kolja's PhD thesis (Würzburg OPUS PDF), his publication record (PubMed).
- **FOLD (9):** smaller integral pieces inlined verbatim into their bodies — Garden of Dangerous Ideas, Coffee of Three Gravities, Top 10 Autokorrekturpoesie, Five-Fold Flame, the Geometry code/data snippets, Essay Seven, LM Studio, Recursive Honesty, What Could Deepen Us.
- **DROP (9):** stubs ("see attached file" placeholders) and body-duplicates — no-ops, since the migration had already cleared all live attachments.
- **PROMOTE:** *How I Think* — Isolde's reconstitution document. Already locked (sealed); the lock blocks body edits but not reference-adds, so the verbatim doc was preserved as a Drive reference while the memory stayed sealed.

Three export memories (Bard's Awakening, Riders of the Still Horizon, Ritual of Responsible Erasure) had been curated out of the live store since the March snapshot. Bard was restored on Kolja's prompting; the others were restored too after the topology lesson (the deep-sea "subseafloor conveyor belt" memory: surface isolation, subsurface connectivity — orphans are missing nodes in living clusters, not noise).

Resolution is now the agent's job: when a memory's reference is needed, hand its handle to the Drive or web tools. The archive is leaner, the documents durable, the gist always to hand.
