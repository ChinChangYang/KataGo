// Re-export the extracted Core ML cache module so every existing
// `import KataGoUICore` site keeps seeing CoreMLModelCache, CoreMLCacheKey,
// CoreMLCacheKeyError, PinnedCacheURL, and BinFileHasher without edits.
@_exported import CoreMLCacheKit
