package main

import (
	"context"
	"log"
	"math/rand"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/shiva/shortest-path-bench/internal/client"
	"github.com/shiva/shortest-path-bench/internal/compare"
	"github.com/shiva/shortest-path-bench/internal/ldbc"
	"github.com/shiva/shortest-path-bench/internal/oracle"
	"github.com/shiva/shortest-path-bench/internal/stats"
)

// kshortest mode is the top-k correctness discriminator. For each sampled
// target it compares Dgraph's returned path-cost VECTOR against the gonum Yen
// oracle's, across a sweep of maxfrontiersize values. Comparing sorted costs
// (not path identity) is tie-robust; the oracle is validated (internal/oracle
// tests) and the loopless-not-disjoint semantics confirmed (cmd/handprobe).
//
// Per (target, frontier) it records: verdict (ok / count_mismatch /
// weight_mismatch), Dgraph's self-consistency (summed facets == reported
// _weight_, loopless), and latency. The per-frontier table shows exactly where
// each binary starts dropping or corrupting paths.
//
// Run once per PR binary against its alpha; aggregate the JSONs across PRs.

type kFrontierStat struct {
	MaxFrontier      int           `json:"max_frontier"` // 0 = unlimited
	Targets          int           `json:"targets"`
	Correct          int           `json:"correct"`
	CorrectPct       float64       `json:"correct_pct"`
	CountMismatch    int           `json:"count_mismatch"`
	WeightMismatch   int           `json:"weight_mismatch"`
	SelfInconsistent int           `json:"self_inconsistent"`
	Errors           int           `json:"errors"`
	Latency          stats.Summary `json:"latency"`
}

type kResult struct {
	Dataset          string          `json:"dataset"`
	Source           int64           `json:"source_vertex"`
	NumPaths         int             `json:"num_paths"`
	Tolerance        float64         `json:"tolerance"`
	CandidateTargets int             `json:"candidate_targets"`
	QualifiedTargets int             `json:"qualified_targets"`
	Frontiers        []kFrontierStat `json:"frontiers"`
}

func runKShortest(ctx context.Context, cfg config, c *client.Client, ds *ldbc.Dataset, uidMap map[int64]string) {
	numPaths := cfg.numPaths
	if numPaths < 2 {
		log.Printf("[kshortest] numpaths=%d; the top-k comparison is most meaningful at >=2 (set -numpaths 2)", numPaths)
	}
	frontiers := parseFrontiers(cfg.frontiers)

	source := ds.Properties.SourceVertex
	if _, ok := uidMap[source]; !ok {
		log.Fatalf("source vertex %d not in graph", source)
	}

	// Build the oracle graph from the same .e stream + directedness the
	// converter used, so the oracle traverses exactly what Dgraph traverses.
	log.Printf("[kshortest] building oracle graph from %s (directed=%v)...", ds.EdgeFile, ds.Properties.Directed)
	start := time.Now()
	g := oracle.New()
	directed := ds.Properties.Directed
	if err := ldbc.ScanEdges(ds.EdgeFile, func(e ldbc.Edge) error {
		if aerr := g.AddEdge(e.Src, e.Dst, e.Weight); aerr != nil {
			return aerr
		}
		if !directed {
			return g.AddEdge(e.Dst, e.Src, e.Weight)
		}
		return nil
	}); err != nil {
		log.Fatalf("build oracle graph: %v", err)
	}
	log.Printf("[kshortest] oracle graph: %d nodes in %s", g.Nodes(), time.Since(start).Round(time.Millisecond))

	// Sample candidate targets and precompute oracle vectors. Keep only targets
	// the oracle finds at least 2 loopless paths to — those are the ones a
	// numpaths>=2 query can actually be wrong about.
	candidates := sampleTargets(uidMap, source, cfg.targets, cfg.seed)
	type pair struct {
		gid    int64
		uid    string
		oracle []float64
	}
	var qualified []pair
	log.Printf("[kshortest] precomputing oracle top-%d for %d candidate targets...", numPaths, len(candidates))
	preStart := time.Now()
	for i, tgt := range candidates {
		vec, err := g.TopK(source, tgt, numPaths)
		if err != nil || len(vec) < 2 {
			continue
		}
		qualified = append(qualified, pair{gid: tgt, uid: uidMap[tgt], oracle: vec})
		if (i+1)%50 == 0 {
			log.Printf("[kshortest] oracle precompute %d/%d (%d qualified) elapsed=%s",
				i+1, len(candidates), len(qualified), time.Since(preStart).Round(time.Second))
		}
	}
	if len(qualified) == 0 {
		log.Fatal("[kshortest] no targets with >=2 oracle paths — try more -targets or a different -source")
	}
	log.Printf("[kshortest] %d/%d targets qualified (>=2 paths) in %s",
		len(qualified), len(candidates), time.Since(preStart).Round(time.Second))

	res := kResult{
		Dataset:          ds.Name,
		Source:           source,
		NumPaths:         numPaths,
		Tolerance:        cfg.tol,
		CandidateTargets: len(candidates),
		QualifiedTargets: len(qualified),
	}

	srcUID := uidMap[source]
	// Sweep largest frontier first: if a binary OOMs/hangs at a big frontier,
	// you learn it before spending time on the cheaper ones.
	for _, fr := range frontiers {
		stat := kFrontierStat{MaxFrontier: fr, Targets: len(qualified)}
		rec := stats.New()
		swStart := time.Now()
		for _, p := range qualified {
			sr, err := c.Shortest(ctx, client.ShortestOptions{
				SrcUID:      srcUID,
				DstUID:      p.uid,
				EdgePred:    cfg.edgePred,
				NumPaths:    numPaths,
				MaxFrontier: fr,
				Timeout:     cfg.timeout,
			})
			if err != nil {
				rec.RecordError()
				stat.Errors++
				continue
			}
			rec.Record(sr.Latency)
			if !sr.SelfConsistent || !sr.Loopless {
				stat.SelfInconsistent++
			}
			r := compare.Vectors(p.oracle, sr.Weights, cfg.tol)
			switch r.Verdict {
			case compare.OK:
				stat.Correct++
			case compare.CountMismatch:
				stat.CountMismatch++
			case compare.WeightMismatch:
				stat.WeightMismatch++
			}
		}
		stat.Latency = rec.Summarize(time.Since(swStart))
		if stat.Targets > 0 {
			stat.CorrectPct = 100 * float64(stat.Correct) / float64(stat.Targets)
		}
		res.Frontiers = append(res.Frontiers, stat)
		log.Printf("[kshortest] frontier=%-7s correct=%d/%d (%.1f%%) cnt_mm=%d wt_mm=%d self_bad=%d err=%d p50=%s p95=%s",
			frontierLabel(fr), stat.Correct, stat.Targets, stat.CorrectPct,
			stat.CountMismatch, stat.WeightMismatch, stat.SelfInconsistent, stat.Errors,
			stat.Latency.P50.Round(time.Millisecond), stat.Latency.P95.Round(time.Millisecond))
	}

	writeJSON(cfg.out, res)
	printKTable(res)
}

func printKTable(res kResult) {
	log.Printf("[kshortest] === %s  source=%d  numpaths=%d  tol=%g  qualified=%d ===",
		res.Dataset, res.Source, res.NumPaths, res.Tolerance, res.QualifiedTargets)
	log.Printf("[kshortest] %-9s | %-8s | %-6s | %-6s | %-8s | %-4s | %-8s | %-8s",
		"frontier", "correct%", "cnt_mm", "wt_mm", "self_bad", "err", "p50", "p95")
	for _, s := range res.Frontiers {
		log.Printf("[kshortest] %-9s | %7.1f%% | %-6d | %-6d | %-8d | %-4d | %-8s | %-8s",
			frontierLabel(s.MaxFrontier), s.CorrectPct, s.CountMismatch, s.WeightMismatch,
			s.SelfInconsistent, s.Errors,
			s.Latency.P50.Round(time.Millisecond), s.Latency.P95.Round(time.Millisecond))
	}
}

func frontierLabel(fr int) string {
	if fr <= 0 {
		return "unlimited"
	}
	return strconv.Itoa(fr)
}

func parseFrontiers(s string) []int {
	var out []int
	for _, tok := range strings.Split(s, ",") {
		tok = strings.TrimSpace(tok)
		if tok == "" {
			continue
		}
		n, err := strconv.Atoi(tok)
		if err != nil {
			log.Fatalf("bad -frontiers value %q: %v", tok, err)
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		log.Fatal("-frontiers produced no values")
	}
	return out
}

// sampleTargets returns up to n vertex ids (other than source) present in the
// uid map, deterministically for a given seed.
func sampleTargets(uidMap map[int64]string, source int64, n int, seed int64) []int64 {
	all := make([]int64, 0, len(uidMap))
	for gid := range uidMap {
		if gid != source {
			all = append(all, gid)
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i] < all[j] })
	if n > 0 && n < len(all) {
		rng := rand.New(rand.NewSource(seed))
		rng.Shuffle(len(all), func(i, j int) { all[i], all[j] = all[j], all[i] })
		all = all[:n]
	}
	return all
}
