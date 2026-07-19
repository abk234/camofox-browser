import fs from 'fs';
import path from 'path';
import { getSearchFallbacks } from '../../lib/search-fallbacks.js';

const serverSource = fs.readFileSync(path.join(process.cwd(), 'server.js'), 'utf8');

describe('search fallbacks', () => {
  test('falls back from the Google macro to DuckDuckGo before Bing', () => {
    expect(getSearchFallbacks('@google_search', 'weather today')).toEqual([
      {
        engine: 'duckduckgo',
        url: 'https://duckduckgo.com/?q=weather%20today',
      },
      {
        engine: 'bing',
        url: 'https://www.bing.com/search?q=weather%20today',
      },
    ]);
  });

  test('does not alter explicit URLs or non-Google macros', () => {
    expect(getSearchFallbacks(null, 'weather today')).toEqual([]);
    expect(getSearchFallbacks('@youtube_search', 'weather today')).toEqual([]);
  });

  test('encodes the fallback query', () => {
    expect(getSearchFallbacks('@google_search', 'C++ & Rust')[0].url)
      .toBe('https://duckduckgo.com/?q=C%2B%2B%20%26%20Rust');
  });

  test('navigation reports the engine used after Google fallback', () => {
    expect(serverSource).toContain("searchFallback = { searchEngine: candidate.engine, fallbackFrom: 'google' }");
    expect(serverSource).toContain('searchFallbackAttempted: searchFallbacks.length > 0');
  });
});
