# Chinese script detection resources

Unmodified dictionaries and LICENSE from [OpenCC ver.1.3.2](https://github.com/BYVoid/OpenCC/tree/ver.1.3.2/data/dictionary), Apache-2.0. Copyright attribution is preserved in LICENSE and dictionary headers. This tag has no root NOTICE file.

TSCharacters.txt and STCharacters.txt are embedded in the API binary. We identify exclusive character forms, excluding identity mappings and ambiguous overlapping forms. No conversion is performed. The majority of exclusive forms determines the row script; a tie remains uncertain. This permits traditional brand names with a minority variant such as 恒順香醋六年陳. Rows with only shared characters use the same majority decision from PP-OCR page context. Simplified-majority, tied, or unknown script retains the disagreement warning. Runtime does not need OpenCC or network access.
