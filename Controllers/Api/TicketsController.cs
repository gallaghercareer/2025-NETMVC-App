using FinalProReRe.Models;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Web.Http;

namespace FinalProReRe.Controllers.Api
{
    [Authorize]
    public class TicketsController : ApiController
    {


        private ApplicationDbContext _context;

        public TicketsController()
        {
            _context = new ApplicationDbContext();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _context.Dispose();
            }
            base.Dispose(disposing);
        }

        //GET    /api/tickets
        public IEnumerable<Ticket> GetTickets()
        {
            return _context.Tickets.ToList();
        }

        //GET PARTIAL /api/ticket/id

        public Ticket Getticket(int id)
        {
            var ticket = _context.Tickets.SingleOrDefault(t => t.Id == id);
            if (ticket == null)
            {
                throw new HttpResponseException(HttpStatusCode.NotFound);
            }

            return ticket;

        }

        [HttpPost]
        [Authorize(Roles = "CanManageTickets")]
        public Ticket CreateTicket (Ticket ticket)
        {
            if (!ModelState.IsValid)
            {
                throw new HttpResponseException(HttpStatusCode.BadRequest);
            }
            _context.Tickets.Add(ticket);
            _context.SaveChanges();
            
            return ticket;
        }

        [HttpPut]
        [Authorize(Roles = "CanManageTickets")]
        public Ticket UpdateTicket(int id, Ticket ticket)
        {
            if (!ModelState.IsValid)
            {
                throw new HttpResponseException(HttpStatusCode.BadRequest);
            }

            var existingTicket = _context.Tickets.SingleOrDefault(t=>t.Id==id); 

            if (existingTicket == null){
                throw new HttpResponseException(HttpStatusCode.NotFound);
            }

            existingTicket.Date = ticket.Date;
            existingTicket.Instructions = ticket.Instructions;
            existingTicket.Resolved = ticket.Resolved;
            existingTicket.Id = ticket.Id;

            _context.SaveChanges();

            return ticket;
            
        }

        [HttpDelete]
        [Authorize(Roles = "CanManageTickets")]
        public void DeleteTicket(int id) {
            var existingTicket = _context.Tickets.SingleOrDefault(t => t.Id == id);
            if (existingTicket == null)
            {
                throw new HttpResponseException(HttpStatusCode.NotFound);
            }

            _context.Tickets.Remove(existingTicket);

            _context.SaveChanges();

        }

    }
}
