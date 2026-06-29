CREATE OR ALTER PROCEDURE dbo.Debug_Print
    @DebugMessage nvarchar(max)           -- Long message to PRINT in <=4000-char chunks
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260629
    PRINT tops out at 4000 unicode characters, which makes it useless for dumping long debug
    strings (assembled dynamic SQL, big diagnostic blobs, etc) in one shot. This procedure walks
    the message and PRINTs it in chunks of up to 4000 characters.

    Rather than slicing blindly at 4000 -- which splits words and lines mid-stream -- each chunk
    breaks on a whitespace character found in its last ~200 characters. We look for a break in
    priority order, always choosing the candidate closest to the end of the printable chunk:
    * New line (CR, LF, or CRLF) -- break at the line ending nearest the end of the chunk.
    * Tab -- if no new line is in the window, break at the last tab.
    * Space -- if neither is present, break at the last space.
    * If the window has no whitespace at all, fall back to a hard 4000-character break.

    The break character is kept at the tail of its chunk, so no characters are ever dropped --
    the concatenation of every chunk reproduces @DebugMessage exactly.

PARAMETERS
* @DebugMessage - The (potentially very long) message to print.

EXAMPLES:
-- Print a long blob of dynamic SQL without truncating at 4000 chars:
-- EXEC dbo.Debug_Print @DebugMessage = @sql;

**************************************************************************************************
MODIFICATIONS:
    20260629 - AM2 - Break chunks on whitespace (new line, then tab, then space) within the last
                     ~200 characters instead of slicing mid-word.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @pos         int = 1,                       -- Start of the current chunk (1-based)
        @len         int = LEN(@DebugMessage),
        @maxChunk    int = 4000,                    -- PRINT's hard unicode limit
        @windowLen   int = 200,                     -- Tail of the chunk we search for whitespace
        @searchStart int,
        @revWindow   nvarchar(200),
        @lfOffset    int,
        @crOffset    int,
        @breakOffset int,                           -- Offset of the break char from the END of the window
        @chunkLen    int;

    WHILE @pos <= @len
    BEGIN
        -- If everything left fits in a single PRINT, emit it and we're done.
        IF @len - @pos + 1 <= @maxChunk
        BEGIN
            PRINT SUBSTRING(@DebugMessage, @pos, @maxChunk);
            BREAK;
        END;

        -- More than 4000 characters remain, so we have to split. Search the last @windowLen
        -- characters of this 4000-char chunk for a whitespace break. Reversing the window once
        -- lets a single CHARINDEX per candidate return the occurrence *closest to the end* of
        -- the chunk: the smaller the CHARINDEX, the nearer the char is to the chunk's tail.
        SET @searchStart = @pos + @maxChunk - @windowLen;
        SET @revWindow   = REVERSE(SUBSTRING(@DebugMessage, @searchStart, @windowLen));

        -- Priority: new line -> tab -> space. A new line may be CR, LF, or CRLF, so check both
        -- characters and take whichever sits closest to the end of the chunk (smallest offset in
        -- the reversed window). For CRLF the LF is nearer the tail, so we naturally break after
        -- the full line ending and keep both characters with the chunk.
        SET @lfOffset = CHARINDEX(NCHAR(10), @revWindow);    -- LF
        SET @crOffset = CHARINDEX(NCHAR(13), @revWindow);    -- CR

        SET @breakOffset =
            CASE
                WHEN @lfOffset > 0 AND @crOffset > 0 THEN
                    CASE WHEN @lfOffset < @crOffset THEN @lfOffset ELSE @crOffset END
                ELSE @lfOffset + @crOffset    -- one (or both) is 0, so this is the non-zero one
            END;

        IF @breakOffset = 0
            SET @breakOffset = CHARINDEX(NCHAR(9), @revWindow);     -- Tab

        IF @breakOffset = 0
            SET @breakOffset = CHARINDEX(NCHAR(32), @revWindow);    -- Space

        IF @breakOffset = 0
            -- No whitespace in the window: nothing to break on, so take the full 4000.
            SET @chunkLen = @maxChunk;
        ELSE
            -- Keep the break char at the tail of this chunk. Its position from the start of the
            -- chunk is (@maxChunk - @breakOffset + 1), since @breakOffset counts from the end.
            SET @chunkLen = @maxChunk - @breakOffset + 1;

        PRINT SUBSTRING(@DebugMessage, @pos, @chunkLen);
        SET @pos = @pos + @chunkLen;
    END;
END;
GO
