// SPDX-License-Identifier: MIT

#[starknet::contract]
mod DocumentSigner {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::get_block_timestamp;
    use starknet::storage::{Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess};
    use core::num::traits::Zero;

    // STRUCTS

    /// Document struct represents a document that needs to be signed by multiple parties
    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct Document {
        id: u64,                        
        sender: ContractAddress,        
        ipfs_hash: felt252,            
        document_name: felt252,        
        document_type: felt252,        
        sent_at: u64,                  
        current_signer_index: u32,     
        status: u8,                    
    }

    // EVENTS
    
    /// Events are emitted to notify external systems about state changes
    /// These events can be listened to by frontend applications or indexers
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        DocumentSent: DocumentSent,           // Emitted when a new document is sent for signing
        DocumentSigned: DocumentSigned,       // Emitted when someone signs a document
        DocumentDeclined: DocumentDeclined,   // Emitted when someone declines to sign
    }

    /// Event emitted when a document is first sent for signing
    /// This is the starting point of the signing workflow
    #[derive(Drop, starknet::Event)]
    struct DocumentSent {
        doc_id: u64,                    // ID of the document that was sent
        sender: ContractAddress,        // Who sent the document
        timestamp: u64,                 // When it was sent
    }

    /// Event emitted each time someone signs a document
    /// Helps track the signing progress
    #[derive(Drop, starknet::Event)]
    struct DocumentSigned {
        doc_id: u64,                    // ID of the document that was signed
        signer: ContractAddress,        // Who signed it
        timestamp: u64,                 // When it was signed
    }

    /// Event emitted when someone declines to sign
    /// This effectively ends the signing process for the document
    #[derive(Drop, starknet::Event)]
    struct DocumentDeclined {
        doc_id: u64,                    // ID of the document that was declined
        signer: ContractAddress,        // Who declined it
        timestamp: u64,                 // When it was declined
    }

    // STORAGE VARIABLES

    #[storage]
    struct Storage {
        /// Main storage for all documents, mapped by document ID
        /// This is where we store the complete document information
        documents: Map<u64, Document>,
        
        /// Counter to generate unique document IDs
        /// Incremented each time a new document is sent
        next_document_id: u64,
        
        /// Maps (document_id, signer_index) to the signer's address
        /// This maintains the order of signers for each document
        document_signers: Map<(u64, u32), ContractAddress>,
        
        /// Tracks when each signer took action on each document
        /// Maps (document_id, signer_address) to timestamp
        signer_action_at: Map<(u64, ContractAddress), u64>,
        
        /// Tracks the status of each signer for each document
        /// Maps (document_id, signer_address) to status
        /// Status values: 0=pending, 1=signed, 2=declined
        signer_status: Map<(u64, ContractAddress), u8>,
    }

    // CONTRACT IMPLEMENTATION

    #[abi(embed_v0)]
    impl DocumentSignerImpl of IDocumentSigner<ContractState> {
        
        /// ENTRY POINT: This function is called first to initiate the signing process
        /// It creates a new document and sets up the signing workflow
        fn send_document(
            ref self: ContractState,
            ipfs_hash: felt252,              // Where the document content is stored
            document_name: felt252,          // Display name for the document
            document_type: felt252,          // Category/type of document
            signers: Array<ContractAddress>  // List of addresses that need to sign (in order)
        ) {
            // Get the address of whoever is calling this function
            // This person becomes the "sender" of the document
            let sender = get_caller_address();
            
            // Record the exact time when this document was sent
            let timestamp = get_block_timestamp();

            // Generate a unique ID for this document
            // Read the current counter and increment it for next time
            let doc_id = self.next_document_id.read();
            self.next_document_id.write(doc_id + 1);

            // Create the document struct with all the provided information
            // Status starts at 0 (pending), current_signer_index starts at 0 (first signer)
            let doc = Document {
                id: doc_id,
                sender,
                ipfs_hash,
                document_name,
                document_type,
                sent_at: timestamp,
                current_signer_index: 0,        // Start with the first signer
                status: 0                       // 0 = pending signatures
            };
            
            // Store the document in the main documents mapping
            self.documents.entry(doc_id).write(doc);

            // Set up the signing order by storing each signer with their index
            // This loop creates the mapping: (doc_id, 0) -> first_signer, (doc_id, 1) -> second_signer, etc.
            let len = signers.len();
            let mut i = 0;
            while i < len {
                let signer = *signers.at(i);
                
                // Map this signer to their position in the signing order
                self.document_signers.entry((doc_id, i)).write(signer);
                
                // Initialize their signing status as pending (0)
                self.signer_status.entry((doc_id, signer)).write(0);
                
                i += 1;
            };

            // Emit an event to notify external systems that a new document was sent
            // This is often the trigger for sending notifications to the first signer
            self.emit(Event::DocumentSent(DocumentSent {
                doc_id,
                sender,
                timestamp
            }));
        }

        /// MAIN WORKFLOW FUNCTION: Called by each signer in turn to sign the document
        /// This function enforces the sequential signing order
        fn sign_document(ref self: ContractState, doc_id: u64) {
            // Get who is trying to sign this document
            let signer = get_caller_address();
            let timestamp = get_block_timestamp();

            // Load the current document state
            let mut doc = self.documents.entry(doc_id).read();
            
            // SECURITY CHECK: Verify this person is supposed to sign next
            // Get the address of who should be signing at the current index
            let expected_signer = self.document_signers.entry((doc_id, doc.current_signer_index)).read();
            
            // Reject the transaction if wrong person is trying to sign
            assert(signer == expected_signer, 'Not the expected signer');

            // Record that this signer has signed (status = 1)
            self.signer_status.entry((doc_id, signer)).write(1);
            
            // Record when they signed (for audit trail)
            self.signer_action_at.entry((doc_id, signer)).write(timestamp);

            // Check if there are more signers after this one
            let next_index = doc.current_signer_index + 1;
            let maybe_next_signer = self.document_signers.entry((doc_id, next_index)).read();

            // If no more signers (next signer is zero address), document is fully signed
            if maybe_next_signer == Zero::zero() {
                doc.status = 1;  // 1 = fully signed and complete
            } else {
                // More signers needed, advance to the next one
                doc.current_signer_index = next_index;
            }

            // Save the updated document state
            self.documents.entry(doc_id).write(doc);
            
            // Emit event to notify that someone signed
            // External systems can use this to send notifications to the next signer
            self.emit(Event::DocumentSigned(DocumentSigned {
                doc_id,
                signer,
                timestamp
            }));
        }

        /// REJECTION FUNCTION: Called when someone refuses to sign
        /// This immediately terminates the signing process for the document
        fn decline_document(ref self: ContractState, doc_id: u64) {
            // Get who is declining to sign
            let signer = get_caller_address();
            let timestamp = get_block_timestamp();

            // Load the current document state
            let mut doc = self.documents.entry(doc_id).read();
            
            // SECURITY CHECK: Only the current expected signer can decline
            let expected_signer = self.document_signers.entry((doc_id, doc.current_signer_index)).read();
            
            // Reject if wrong person is trying to decline
            assert(signer == expected_signer, 'Not the expected signer');

            // Record that this signer declined 
            self.signer_status.entry((doc_id, signer)).write(2);
            
            // Record when they declined
            self.signer_action_at.entry((doc_id, signer)).write(timestamp);

            // Mark the entire document as declined 
            // This effectively ends the signing process - no one else can sign after a decline
            doc.status = 2;
            self.documents.entry(doc_id).write(doc);

            // Emit event to notify external systems of the decline
            self.emit(Event::DocumentDeclined(DocumentDeclined {
                doc_id,
                signer,
                timestamp
            }));
        }

        /// QUERY FUNCTION: Returns the current state of a document
        /// This is a read-only function that doesn't modify state
        /// Used by frontend applications to display document status
        fn get_document(self: @ContractState, doc_id: u64) -> Document {
            self.documents.entry(doc_id).read()
        }
    }

    // INTERFACE DEFINITION
    
    /// This interface defines all the functions that external callers can use
    /// It serves as the contract's public API
    #[starknet::interface]
    trait IDocumentSigner<TContractState> {
        /// Send a new document for signing - this starts the workflow
        fn send_document(
            ref self: TContractState,
            ipfs_hash: felt252,
            document_name: felt252,
            document_type: felt252,
            signers: Array<ContractAddress>
        );
        
        /// Sign a document - called by each signer in sequence
        fn sign_document(ref self: TContractState, doc_id: u64);
        
        /// Decline to sign a document - ends the process
        fn decline_document(ref self: TContractState, doc_id: u64);
        
        /// Get document information - read-only query
        fn get_document(self: @TContractState, doc_id: u64) -> Document;
    }
}