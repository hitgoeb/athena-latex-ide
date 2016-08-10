class FileManager
{

    private static uint NEXT_NEW_FILE_INDEX = 1;

    public class File
    {
        private string? _path;
        private string? _contents;
        private GLib.File? file;
        private GLib.FileMonitor? monitor;

        public int    position { public get; internal set; }
        public uint   flags    { public get; internal set; }
        public string label    { public get;  private set; }
        public uint   hash     { public get; internal set; }

        /**
         * Indicates, that `file` was changed by this or another program.
         */
        public signal void changed( File file );

        public string? path
        {
            public get
            {
                return _path;
            }
            internal set
            {
                this._path = value;
                this.stop_monitor();
                if( value == null )
                {
                    uint new_file_index = NEXT_NEW_FILE_INDEX++;
                    this.label = "New File %u".printf( new_file_index );
                    this.file  = null;
                }
                else
                {
                    this.label   = GLib.Path.get_basename( this.path );
                    this.file    = GLib.File.new_for_path( this.path );
                    this.monitor = this.file.monitor( GLib.FileMonitorFlags.NONE, null );
                    if( _contents != null )
                    {
                        this.set_contents( _contents );
                        this._contents = null;
                    }
                }
            }
        }

        public string get_contents()
        {
            string contents;
            if( _contents != null )
            {
                contents = _contents;
            }
            else
            {
                if( path == null )
                {
                    contents = "";
                }
                else
                {
                    bool first_line = true;
                    string line;
                    var data  = new StringBuilder();
                    var input = new DataInputStream( file.read() );
                    while( ( line = input.read_line( null ) ) != null )
                    {
                        data.append( ( first_line ? "%s" : "\n%s" ).printf( line ) );
                        first_line = false;
                    }
                    contents = data.str;
                }
            }
            hash = contents.hash();
            return contents;
        }

        public void set_contents( string contents )
        {
            hash = contents.hash();
            if( path == null )
            {
                _contents = contents;
            }
            else
            {
                file.replace_contents( contents.data, null, false, GLib.FileCreateFlags.NONE, null, null );
            }
        }

        public bool has_flags( uint flags )
        {
            return ( this.flags & flags ) != 0;
        }

        internal File( string? path, int position, uint flags )
        {
            this.path     = path;
            this.position = position;
            this.flags    = flags;
        }

        internal void start_monitor( FileManager manager )
        {
            if( this.monitor != null )
            {
                this.monitor.changed.connect( ( file, other_file, event_type ) =>
                    {
                        changed( this );
                    }
                );
            }
        }

        internal void stop_monitor()
        {
            if( this.monitor != null )
            {
                this.monitor.cancel();
                this.monitor = null;
            }
        }
    }

    private Gee.LinkedList< File > files = new Gee.LinkedList< File >();
    private int named_files = 0;

    public uint     new_file_flags { get; set; default = 0; }
    public uint default_file_flags { get; set; default = 0; }

    private int get_insert_position_for_named( string path, int first, int last )
        ensures( result >= first )
        ensures( result <=  last )
    {
        stdout.printf( "get_insert_position_for_named: first = %d, last = %d\n", first, last );
        if( last - first <= 1 )
        {
            if( path <= files[ first ].path )
            {
                return first;
            }
            else
            {
                return last;
            }
        }
        else
        {
            int mid = (first + last) / 2;
            if( path < files[ mid ].path )
            {
                return get_insert_position_for_named( path, first, mid );
            }
            else
            {
                return get_insert_position_for_named( path, mid, last );
            }
        }
    }

    public int find_position( string path )
        ensures( result >= -1 )
        ensures( result < files.size )
    {
        if( named_files == 0 )
        {
            return -1;
        }
        else
        {
            var position = get_insert_position_for_named( path, 0, named_files );
            return position < files.size && files[ position ].path == path ? position : -1;
        }
    }

    private int get_insert_position( string? path )
        ensures( result >= 0 )
        ensures( result <= files.size )
    {
        if( path == null )
        {
            return files.size;
        }
        else
        if( named_files == 0 )
        {
            return 0;
        }
        else
        {
            return get_insert_position_for_named( path, 0, named_files );
        }
    }

    public File open( string? path )
    {
        int position = get_insert_position( path );

        /* Assert that `path` isn't already open.
         */
        assert( position == files.size || files[ position ].path != path );

        var file = open_ex( path, position );
        return file;
    }

    /**
     * Closes the file at `position` and sets it position to `-1`.
     */
    public void close( int position )
        requires( position >= 0 )
        requires( position < files.size )
    {
        var file = files[ position ];
        remove_file( file );
        file.position = -1;
        invalidate( position, files.size - position + 1 );
    }

    private File open_ex( string? path, int position )
        requires( position >= 0 )
        requires( position <= files.size )
    {
        var flags = path == null ? new_file_flags : default_file_flags;
        var file  = new File( path, position, flags );
        insert_file( file );
        invalidate( position, files.size - position );
        return file;
    }

    /**
     * Enlists `file` without notifying anyone.
     *
     * This is an atomic, most low-level operation.
     * The `position` of the `file` is allowed to be *right after* the last element.
     */
    private void insert_file( File file )
        requires( file.position >= 0 )
        requires( file.position <= files.size )
    {
        if( file.path != null )
        {
            ++named_files;
        }
        for( int idx = file.position; idx < files.size; ++idx )
        {
            ++files[ idx ].position;
        }
        files.insert( file.position, file );
        file.start_monitor( this );
    }

    /**
     * Withdraws `file` without notifying anyone.
     *
     * This is an atomic, most low-level operation.
     */
    private void remove_file( File file )
        requires( file.position >= 0 )
        requires( file.position < files.size )
    {
        file.stop_monitor();
        files.remove_at( file.position );
        for( int idx = file.position; idx < files.size; ++idx )
        {
            --files[ idx ].position;
        }
        if( file.path != null )
        {
            --named_files;
        }
        if( files.size == named_files )
        {
            NEXT_NEW_FILE_INDEX = 1;
        }
    }

    public File get( int position )
        requires( position >= 0 )
        requires( position < files.size )
    {
        return files[ position ];
    }

    public void set_flags( int position, uint mask, bool on = true )
        requires( position >= 0 )
        requires( position < files.size )
    {
        if( on )
        {
            files[ position ].flags |= mask;
        }
        else
        {
            files[ position ].flags ^= mask & files[ position ].flags;
        }
        invalidate( position, 1 );
    }

    public File set_path( int position, string? path )
        requires( position >= 0 )
        requires( position < files.size )
    {
        var file = this[ position ];
        remove_file( file );
        file.path = path;
        file.position = get_insert_position( path );
        insert_file( file );
        int first_invalid = Utils.min( position, file.position );
        int  last_invalid = Utils.max( position, file.position );
        invalidate( first_invalid, last_invalid - first_invalid + 1 );
        return file;
    }

    private void invalidate( int first, int count )
        requires( first >= 0 )
        requires( first + count <= files.size + 1 )
    {
        invalidated( first, count );
    }

    public signal void invalidated( int first, int count );

    public int count
    {
        get
        {
            return files.size;
        }
    }

    public Gee.Iterator< File > iterator()
    {
        return files.iterator();
    }

}